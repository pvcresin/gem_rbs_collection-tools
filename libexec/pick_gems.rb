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
require "net/http"; require "json"; require "fileutils"; require "time"; require "digest"
repo = ARGV[0] or abort "usage: ruby pick_gems.rb <gem_rbs_collection dir> [--top N] [--limit N]"
top = (ARGV[ARGV.index("--top") + 1] rescue nil)&.to_i || 500
limit = (ARGV[ARGV.index("--limit") + 1] rescue nil)&.to_i || 30
min_months = (ARGV[ARGV.index("--min-months") + 1] rescue nil)&.to_i
CACHE = File.expand_path("~/.cache/pick_gems"); FileUtils.mkdir_p(CACHE)
def get(url)
  f = File.join(CACHE, Digest::SHA1.hexdigest(url))
  return File.read(f, encoding: "UTF-8") if File.exist?(f) && Time.now - File.mtime(f) < 86_400
  sleep 0.15
  res = Net::HTTP.get_response(URI(url))
  raise "#{url}: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  File.write(f, res.body); res.body.force_encoding("UTF-8")
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
  next if status == 2
  begin
    info = JSON.parse(get("https://rubygems.org/api/v1/gems/#{name}.json"))
    versions = JSON.parse(get("https://rubygems.org/api/v1/versions/#{name}.json"))
  rescue => e
    warn "skip #{name}: #{e.message}"; next
  end
  latest = versions.find { |v| !v["prerelease"] } or next
  released = Time.parse(latest["created_at"])
  recent = versions.count { |v| !v["prerelease"] && Time.parse(v["created_at"]) > Time.now - 2 * 365 * 86_400 }
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
# The shortlist gets the slower checks, one gem at a time:
# - does the gem ship its own RBS? (any .rbs file in the package, usually
#   sig/). Those are skipped: they already have types.
# - is there an open pull request for it in ruby/gem_rbs_collection?
#   (needs the gh CLI; skipped with --no-pr-check)
def bundled_rbs(name, version)
  files = `gem specification --remote #{name} -v #{version} files 2>/dev/null`.lines.map { _1.sub(/\A- /, "").strip }
  rbs = files.grep(/\.rbs\z/)
  rbs.empty? ? nil : (rbs.any? { _1.start_with?("sig/") } ? "sig/" : rbs.first)
end

def open_pr(name)
  q = "repo:ruby/gem_rbs_collection is:pr is:open in:title #{name}"
  out = `gh api -X GET search/issues -f q=#{q.dump} --jq '.items[] | "#\\(.number) \\(.title)"' 2>/dev/null`
  sleep 2.5 # search API: a few requests per minute
  out.lines.map(&:strip).find { |t| t.match?(/\b#{Regexp.escape(name)}\b/i) }
end

check_prs = !ARGV.include?("--no-pr-check") && system("command -v gh >/dev/null 2>&1")
picked = []
rows.each do |r|
  break if picked.size >= limit
  if (rbs = bundled_rbs(r[:name], r[:version]))
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
