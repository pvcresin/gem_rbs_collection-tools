# Writes the Gemfile used to run a gem's own tests (see prepare_gem.sh).
#
# Usage: ruby env_gemfile.rb <gem package (.gem)> <repo dir> > env/Gemfile
#
# - Dependencies come from the packaged gem's metadata, not the repo's
#   gemspec: Bundler evaluates a gemspec at startup and many gemspecs
#   `require` the library, which would load it before any tracing hook.
#   The tests load the library from repo/lib (-Ilib).
# - Gems from the repo's Gemfile / gems.rb are added (test runners and
#   helpers often live only there), minus linters, debuggers and CI tools.
#   Options such as path:/git: are dropped; prune lines if bundle fails.
# - rbs, rbs-trace and lumitrace are added for gem-types.
require "rubygems/package"

pkg, repo = ARGV
spec = Gem::Package.new(pkg).spec
lines = ['source "https://rubygems.org"', "",
         "# #{spec.name} #{spec.version}: dependencies from the gem package; the gem itself loads from repo/lib"]
names = []
spec.dependencies.each do |d|
  reqs = d.requirement.requirements.map { |op, v| "#{op} #{v}" }.reject { _1 == ">= 0" }
  lines << ["gem #{d.name.dump}", *reqs.map(&:dump)].join(", ") + (d.type == :development ? " # development" : "")
  names << d.name
end

SKIP = /\A(rubocop.*|standard|guard.*|pry.*|byebug|debug|coveralls.*|codeclimate.*|ruby-prof|yard|rdoc|bundler|bake.*|covered|sus-fixtures-.*|rake-compiler|gem-release|overcommit|reek|flay|flog|panolint)\z/
gemfile = %w[Gemfile gems.rb].map { File.join(repo, _1) }.find { File.file?(_1) }
if gemfile
  extra = []
  File.foreach(gemfile) do |l|
    m = l.match(/^\s*gem\s+["']([^"']+)["']\s*(.*)$/) or next
    name = m[1]
    next if name == spec.name || names.include?(name) || name.match?(SKIP)

    versions = m[2].scan(/["']([~<>=! ]*\d[^"']*)["']/).flatten
    extra << ["gem #{name.dump}", *versions.map(&:dump)].join(", ")
    names << name
  end
  unless extra.empty?
    lines << "" << "# From #{File.basename(gemfile)} in the repository (remove lines that do not install)"
    lines.concat(extra)
  end
end

lines << "" << "# For gem-types"
%w[rbs lumitrace rbs-trace].each { |g| lines << "gem #{g.dump}" unless names.include?(g) }
puts lines
