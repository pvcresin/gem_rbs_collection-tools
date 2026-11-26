# Ranks candidate gems for gem_rbs_collection.
#
# Usage: ruby pick_gems.rb <path to gem_rbs_collection checkout> [--top 500] [--limit 30] [--min-months N] [--no-pr-check]
#
# Priority, in order:
#   1. among the top N gems by total downloads (bestgems.org ranking)
#   2. not in the collection yet (no gems/<name>/), so no reviewers;
#      then existing gems with no _reviewers.yaml
#   3. no new release for a long time (signatures stay current longer)
# With --min-months N, only gems whose latest release is at least N months
# old are listed, ordered by status then download rank (avoids a list of
# long-abandoned gems at the top).
# Skips gems whose package ships RBS (any .rbs file, usually sig/), gems
# whose RBS is bundled with the rbs gem (stdlib/), and gems with an open PR
# in ruby/gem_rbs_collection (--no-pr-check to skip that check). Untyped
# gems are the point: those are the ones the collection should cover. Caches HTTP responses in
# ~/.cache/pick_gems for a day.
require "net/http"; require "json"; require "optparse"; require "open3"
require "shellwords"; require "fileutils"; require "time"; require "digest"
CACHE = File.expand_path("~/.cache/pick_gems"); FileUtils.mkdir_p(CACHE)
def get(url)
  f = File.join(CACHE, Digest::SHA1.hexdigest(url))
  return File.read(f, encoding: "UTF-8") if File.exist?(f) && Time.now - File.mtime(f) < 86_400
  sleep 0.15
  res = Net::HTTP.get_response(URI(url))
  raise "#{url}: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  File.write(f, res.body); res.body.force_encoding("UTF-8")
end
# The shortlist gets the slower checks, one gem at a time:
# - does the gem ship its own RBS? (any .rbs file in the package, usually
#   sig/). Those are skipped: they already have types.
# - is there an open pull request for it in ruby/gem_rbs_collection?
#   (needs the gh CLI; skipped with --no-pr-check)
# `gem specification --remote` has no file list (it is always empty), so
# the package is fetched and its data.tar.gz listed (cached per version).
# Returns nil when the package cannot be fetched or listed (not cached, so
# the next run tries again).
def package_files(name, version)
  f = File.join(CACHE, "files-#{name}-#{version}")
  # An empty list is a failed listing cached by older versions of this script.
  cached = File.exist?(f) ? File.read(f).lines(chomp: true) : []
  return cached unless cached.empty?

  require "tmpdir"
  list = Dir.mktmpdir do |dir|
    # The pure-Ruby package if there is one, else whatever gem fetch picks.
    fetch = ->(*plat) { system("gem", "fetch", name, "-v", version, *plat, chdir: dir, out: File::NULL, err: File::NULL) }
    fetch.("--platform", "ruby")
    fetch.() if Dir[File.join(dir, "*.gem")].empty?
    pkg = Dir[File.join(dir, "*.gem")].first or next nil
    out, st = Open3.capture2("bash", "-c", "set -o pipefail; tar -xOf #{pkg.shellescape} data.tar.gz | tar -tz", err: File::NULL)
    st.success? ? out.lines(chomp: true) : nil
  end
  File.write(f, list.join("\n")) if list
  list
end

# "sig/" or the first .rbs file the package ships, nil if none, :unknown
# if the package could not be listed.
def bundled_rbs(name, version)
  files = package_files(name, version) or return :unknown
  rbs = files.grep(/\.rbs\z/)
  rbs.empty? ? nil : (rbs.any? { _1.start_with?("sig/") } ? "sig/" : rbs.first)
end

# The first open PR in ruby/gem_rbs_collection whose title names the gem
# as a whole word ("rack-test" does not name "rack"). Aborts when gh fails:
# a failed search must not read as "no PR".
def open_pr(name)
  q = "repo:ruby/gem_rbs_collection is:pr is:open in:title #{name}"
  out = st = err = nil
  2.times do |i|
    out, err, st = Open3.capture3("gh", "api", "-X", "GET", "search/issues", "-f", "q=#{q}", "-f", "per_page=100",
                                  "--paginate", "--jq", '.items[] | "#\(.number) \(.title)"')
    sleep 2.5 # search API: a few requests per minute
    break if st.success?

    sleep 30 if i.zero? # rate limit: wait once, then give up
  end
  abort "gh search for open PRs on #{name} failed: #{err.strip}\n(rerun later, or pass --no-pr-check)" unless st.success?
  out.lines.map(&:strip).find { |t| names_gem?(t, name) }
end

# Whether a PR title names the gem: a whole word, where "-" is part of the
# word (gem names have dashes).
def names_gem?(title, name)
  title.match?(/(?<![\w-])#{Regexp.escape(name)}(?![\w-])/i)
end


if $PROGRAM_NAME == __FILE__
  top = 500; limit = 30; min_months = nil; pr_check = true
  args = OptionParser.new do |o|
    o.banner = "usage: ruby pick_gems.rb <gem_rbs_collection dir> [--top N] [--limit N] [--min-months N] [--no-pr-check]"
    o.on("--top N", Integer) { top = _1 }
    o.on("--limit N", Integer) { limit = _1 }
    o.on("--min-months N", Integer) { min_months = _1 }
    o.on("--[no-]pr-check") { pr_check = _1 }
  end.parse(ARGV)
  repo = args.first or abort "usage: ruby pick_gems.rb <gem_rbs_collection dir> [--top N] [--limit N]"
  names = []
  (1..(top / 20.0).ceil).each do |page|
    html = get("https://bestgems.org/total?page=#{page}")
    names.concat(html.scan(%r{href="/gems/([^"/?#]+)"}).flatten.uniq)
  end
  names = names.uniq.first(top)
  stdlib = begin
    dir = File.join(Gem::Specification.find_by_name("rbs").full_gem_path, "stdlib")
    Dir.children(dir)
  rescue Gem::MissingSpecError
    []
  end
  rows = []
  names.each_with_index do |name, i|
    next if stdlib.include?(name)
    gdir = File.join(repo, "gems", name)
    status = if !Dir.exist?(gdir) then 0                       # new gem
             elsif !File.exist?(File.join(gdir, "_reviewers.yaml")) then 1
             else 2 end
    next if status == 2
    begin
      info = JSON.parse(get("https://rubygems.org/api/v1/gems/#{name}.json"))
      versions = JSON.parse(get("https://rubygems.org/api/v1/versions/#{name}.json"))
    rescue => e
      warn "skip #{name}: #{e.message}"; next
    end
    latest = versions.find { |v| !v["prerelease"] } or next
    released = Time.parse(latest["created_at"])
    # Platform builds (ffi-1.17.2-x86_64-linux, ...) are one release.
    recent = versions.select { |v| !v["prerelease"] && Time.parse(v["created_at"]) > Time.now - 2 * 365 * 86_400 }
                     .map { _1["number"] }.uniq.size
    rows << { rank: i + 1, name: name, status: status, version: latest["number"],
              months: ((Time.now - released) / (30 * 86_400)).round,
              releases_2y: recent, existing: Dir.exist?(gdir) ? Dir.children(gdir).grep(/\A\d/).sort.join(",") : "" ,
              source: info["source_code_uri"] || info["homepage_uri"] }
  end
  if min_months
    rows.select! { |r| r[:months] >= min_months }
    rows.sort_by! { |r| [r[:status], r[:rank]] }
  else
    rows.sort_by! { |r| [r[:status], -r[:months], r[:rank]] }
  end
  check_prs = pr_check && system("command -v gh >/dev/null 2>&1")
  picked = []
  rows.each do |r|
    break if picked.size >= limit
    rbs = bundled_rbs(r[:name], r[:version])
    if rbs == :unknown
      warn "skip #{r[:name]}: could not fetch or list the #{r[:version]} package to check for RBS"; next
    elsif rbs
      warn "skip #{r[:name]}: ships its own RBS (#{rbs})"; next
    end
    if check_prs && (pr = open_pr(r[:name]))
      warn "skip #{r[:name]}: open PR #{pr}"; next
    end
    picked << r
  end
  puts %w[rank gem status latest months_since_release releases_2y in_collection source].join("\t")
  picked.each do |r|
    puts [r[:rank], r[:name], %w[new no-reviewer][r[:status]], r[:version], r[:months], r[:releases_2y], r[:existing], r[:source]].join("\t")
  end
end
