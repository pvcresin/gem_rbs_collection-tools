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
  next if d.name == "bundler" # the running Bundler is used; old bounds only conflict
  reqs = d.requirement.requirements.map { |op, v| "#{op} #{v}" }.reject { _1 == ">= 0" }
  lines << ["gem #{d.name.dump}", *reqs.map(&:dump)].join(", ") + (d.type == :development ? " # development" : "")
  names << d.name
end

SKIP = /\A(rubocop.*|standard|guard.*|pry.*|byebug|debug|coveralls.*|codeclimate.*|ruby-prof|yard|yard-.*|rdoc|bundler|bake.*|covered|sus-fixtures-.*|rake-compiler|gem-release|overcommit|reek|flay|flog|panolint|mutant.*|simplecov.*|rubysl.*)\z/
gemfile = %w[Gemfile gems.rb].map { File.join(repo, _1) }.find { File.file?(_1) }
if gemfile
  extra = []
  # Blocks for other platforms (platforms :jruby, :rbx do ... end) are skipped.
  mri = ->(list) { list.empty? || list.any? { |x| x.match?(/\A(ruby|mri|cruby)/) } }
  skip_until = nil
  File.foreach(gemfile) do |l|
    indent = l[/\A\s*/].size
    if skip_until
      skip_until = nil if l.match?(/^\s*end\b/) && indent <= skip_until
      next
    end
    # Groups the tests do not need (docs, release): their gems may not
    # load without the tools skipped above (yard-sitemap needs its yard).
    if (gm = l.match(/^\s*group\s*\(?\s*(.+?)\)?\s+do\b/)) && gm[1].scan(/:(\w+)/).flatten.all? { %w[doc docs documentation release benchmark benchmarks].include?(_1) }
      skip_until = indent
      next
    end
    if (pm = l.match(/^\s*platforms?\s*\(?\s*(.+?)\)?\s+do\b/))
      skip_until = indent unless mri.(pm[1].scan(/:(\w+)/).flatten)
      next
    end
    m = l.match(/^\s*gem\s+["']([^"']+)["']\s*(.*)$/) or next
    if (pm = m[2].match(/platforms?:\s*(\[[^\]]*\]|:\w+)/))
      next unless mri.(pm[1].scan(/:(\w+)/).flatten)
    end
    name = m[1]
    next if name == spec.name || names.include?(name) || name.match?(SKIP)

    # Conditional versions (RUBY_VERSION < '1.9' ? '~> 10.5' : '>= 10.5')
    # cannot be read without evaluating Ruby: take the gem unconstrained.
    versions = m[2].match?(/RUBY_VERSION|RUBY_ENGINE|\?|\bif\b|\bunless\b/) ? [] : m[2].scan(/["']([~<>=! ]*\d[^"']*)["']/).flatten
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
