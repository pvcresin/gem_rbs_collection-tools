# Prints a likely command to run a gem's own test suite, from its layout.
#
# Usage: ruby detect_test_cmd.rb <repo dir> <env Gemfile>
require "pathname"
repo = Pathname(ARGV[0])
gemfile = File.exist?(ARGV[1].to_s) ? File.read(ARGV[1]) : ""
rakefile = %w[Rakefile rakefile Rakefile.rb].map { repo / _1 }.find(&:file?)
rake = rakefile ? rakefile.read : ""
has = ->(g) { gemfile.match?(/^\s*gem\s+["']#{Regexp.escape(g)}["']/) }

if (repo / "spec").directory? && (has.("rspec") || (repo / ".rspec").file?)
  puts "bundle exec rspec"
elsif (repo / "test").directory?
  files = Dir.chdir(repo) { Dir["test/**/{*_test,test_*}.rb"] }
  if rake.match?(/TestTask|task\s*[(:]?\s*:?test\b/)
    puts "bundle exec rake test"
  elsif !files.empty?
    puts "for t in test/**/*_test.rb test/**/test_*.rb; do [ -f \"$t\" ] && bundle exec ruby -Ilib -Itest \"$t\"; done"
  end
elsif (repo / "spec").directory?
  puts "bundle exec rspec"
end
