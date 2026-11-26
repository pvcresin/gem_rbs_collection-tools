# Ranks candidate gems for gem_rbs_collection.
#
# Usage: ruby pick_gems.rb <path to gem_rbs_collection checkout> [--top 500] [--limit 30] [--min-months N] [--no-pr-check] [--improve]
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
# whose upstream repository has RBS for them (fix those upstream), gems
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

# The gem's source repository, as prepare_gem.sh finds it: the first
# GitHub/GitLab URL in the gem's metadata.
def source_repo(info)
  meta = info["metadata"] || {}
  u = [info["source_code_uri"], info["homepage_uri"], info["bug_tracker_uri"], info["changelog_uri"],
       meta["source_code_uri"], meta["homepage_uri"], meta["bug_tracker_uri"], meta["changelog_uri"],
       info["documentation_uri"], info["wiki_uri"]].compact.find { |x| x =~ %r{(github|gitlab)\.com/[^/]+/[^/]+} }
  u &&= u[%r{\Ahttps?://(?:github|gitlab)\.com/[^/]+/[^/#?]+}]
  u&.sub(/\.git\z/, "")&.sub(%r{\Ahttp://}, "https://")
end

# RBS for the gem in its source repository's default branch, even when the
# package does not ship it (aws-sdk-ruby keeps gems/aws-sigv4/sig/ out of
# the .gem). Maintainers then ask to fix the signatures upstream: a copy in
# the collection is not what users load (ruby/gem_rbs_collection#1195).
# Lists the tree without blobs (git clone --filter=blob:none), cached per
# repository for a day. Returns the first matching path, nil, or :unknown.
def upstream_rbs(name, repo_url)
  return nil unless repo_url

  f = File.join(CACHE, "tree-" + Digest::SHA1.hexdigest(repo_url))
  files = if File.exist?(f) && Time.now - File.mtime(f) < 86_400
            File.read(f).lines(chomp: true)
          else
            require "tmpdir"
            list = Dir.mktmpdir do |dir|
              ok = system("git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--no-checkout", repo_url, File.join(dir, "r"),
                          out: File::NULL, err: File::NULL)
              next nil unless ok

              out, st = Open3.capture2("git", "-C", File.join(dir, "r"), "ls-tree", "-r", "--name-only", "HEAD")
              st.success? ? out.lines(chomp: true) : nil
            end
            return :unknown unless list

            File.write(f, list.join("\n"))
            list
          end
  rbs = files.grep(/\.rbs\z/)
  # The gem's own sig/: at the root (a one-gem repository), or under the
  # gem's directory in a monorepo (gems/<name>/sig, <name>/sig).
  mine = rbs.find { |p| p.start_with?("sig/") || p.match?(%r{(\A|/)#{Regexp.escape(name)}/sig/}) }
  return mine.split("/sig/").first + "/sig/" if mine&.include?("/sig/")

  mine
end

# The first open PR in ruby/gem_rbs_collection whose title names the gem
# as a whole word ("rack-test" does not name "rack"). Aborts when gh fails:
# a failed search must not read as "no PR".
def open_pr(name, state = "is:open")
  q = "repo:ruby/gem_rbs_collection is:pr #{state} in:title #{name}"
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


# Room for improvement of a gem already in the collection: whether the
# newest version directory lags the latest release, the share of untyped
# declarations, and the RBS-only lint findings.
def improvement(gdir, latest)
  dirs = Dir.children(gdir).grep(/\A\d/).sort_by { Gem::Version.new(_1) }
  newest = dirs.last or return nil
  mm = latest.split(".").first(2).join(".")
  files = Dir[File.join(gdir, newest, "**", "*.rbs")].reject { _1.include?("/_") }
  text = files.map { File.read(_1, encoding: "UTF-8") }.join("\n")
  decl = text.lines.grep(/^\s*(def |attr_|[A-Z]\w*: |type )/)
  untyped = decl.empty? ? 0.0 : decl.count { _1.include?("untyped") }.to_f / decl.size
  { newest: newest, outdated: Gem::Version.new(newest) < Gem::Version.new(mm) ? mm : nil,
    untyped: untyped.round(2), decls: decl.size }
end

if $PROGRAM_NAME == __FILE__
  top = 500; limit = 30; min_months = nil; pr_check = true; improve = false
  args = OptionParser.new do |o|
    o.banner = "usage: ruby pick_gems.rb <gem_rbs_collection dir> [--top N] [--limit N] [--min-months N] [--no-pr-check] [--improve]"
    # --improve: gems already in the collection whose signatures are the
    # ones users load (no RBS in the package or the upstream repository),
    # ranked by downloads, with what could be improved.
    o.on("--improve") { improve = true }
    o.on("--top N", Integer) { top = _1 }
    o.on("--limit N", Integer) { limit = _1 }
    o.on("--min-months N", Integer) { min_months = _1 }
    o.on("--[no-]pr-check") { pr_check = _1 }
  end.parse(ARGV)
  repo = args.first or abort "usage: ruby pick_gems.rb <gem_rbs_collection dir> [--top N] [--limit N]"
  # The checkout decides what is "in the collection": a fork's main that
  # lags upstream lists gems that were added or improved since.
  local = `git -C #{repo.shellescape} rev-parse HEAD 2>/dev/null`.strip
  remote = `git ls-remote https://github.com/ruby/gem_rbs_collection refs/heads/main 2>/dev/null`.split.first
  if remote && !local.empty? && local != remote &&
     !system("git", "-C", repo, "merge-base", "--is-ancestor", remote, "HEAD", out: File::NULL, err: File::NULL)
    warn "WARNING: #{repo} is not at ruby/gem_rbs_collection's main (#{remote[0, 8]}): " \
         "git -C #{repo} fetch https://github.com/ruby/gem_rbs_collection main && git -C #{repo} merge --ff-only FETCH_HEAD"
  end
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
    if improve
      next unless Dir.exist?(gdir)
    elsif status == 2
      next
    end
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
              source: info["source_code_uri"] || info["homepage_uri"], repo: source_repo(info),
              improve: improve ? improvement(gdir, latest["number"]) : nil }
  end
  if improve
    rows.select! { |r| r[:improve] }
    rows.sort_by! { |r| r[:rank] }
  elsif min_months
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
    up = upstream_rbs(r[:name], r[:repo])
    if up == :unknown
      warn "note #{r[:name]}: could not list #{r[:repo]} to check for upstream RBS"
    elsif up
      warn "skip #{r[:name]}: the upstream repository has RBS (#{r[:repo]} #{up}); fix it there"; next
    end
    if check_prs && (pr = open_pr(r[:name]))
      warn "skip #{r[:name]}: open PR #{pr}"; next
    end
    # A PR closed without merging in the last half year: read why before
    # trying again (#1195 was closed because the RBS belongs upstream).
    since = (Time.now - 180 * 86_400).strftime("%Y-%m-%d")
    if check_prs && (pr = open_pr(r[:name], "is:closed is:unmerged closed:>=#{since}"))
      warn "skip #{r[:name]}: PR #{pr} was closed without merging; read its comments first"; next
    end
    picked << r
  end
  if improve
    puts %w[rank gem latest collection outdated untyped decls reviewers source].join("\t")
    picked.each do |r|
      i = r[:improve]
      puts [r[:rank], r[:name], r[:version], i[:newest], i[:outdated] || "-", i[:untyped], i[:decls],
            r[:status] == 2 ? "yes" : "no", r[:source]].join("\t")
    end
    exit
  end
  puts %w[rank gem status latest months_since_release releases_2y in_collection source].join("\t")
  picked.each do |r|
    puts [r[:rank], r[:name], %w[new no-reviewer][r[:status]], r[:version], r[:months], r[:releases_2y], r[:existing], r[:source]].join("\t")
  end
end
