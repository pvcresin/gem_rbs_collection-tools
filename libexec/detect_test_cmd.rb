# Prints a likely command to run a gem's own test suite, from its layout.
# When a repo has both spec/ and test/, both are run.
#
# Usage: ruby detect_test_cmd.rb <repo dir> <env Gemfile>
require "pathname"
repo = Pathname(ARGV[0])
gemfile = File.exist?(ARGV[1].to_s) ? File.read(ARGV[1]) : ""
rakefile = %w[Rakefile rakefile Rakefile.rb].map { repo / _1 }.find(&:file?)
rake = rakefile ? rakefile.read : ""
has = ->(g) { gemfile.match?(/^\s*gem\s+["']#{Regexp.escape(g)}["']/) }

cmds = []
cmds << "bundle exec rspec" if (repo / "spec").directory? && (has.("rspec") || (repo / ".rspec").file? || !(repo / "test").directory?)
if (repo / "test").directory?
  named = Dir.chdir(repo) { Dir["test/**/{*_test,test_*}.rb"] }
  if rake.match?(/TestTask|task\s*[(:]?\s*:?test\b/) && !named.empty?
    cmds << "bundle exec rake test"
  elsif !named.empty?
    cmds << "for t in test/**/*_test.rb test/**/test_*.rb; do [ -f \"$t\" ] && bundle exec ruby -Ilib -Itest \"$t\"; done"
  else
    # test/unit/*.rb style without the usual names (e.g. coderay): run
    # every file under test/unit and test/functional that defines tests.
    files = Dir.chdir(repo) { Dir["test/{unit,functional}/*.rb"] }
      .reject { |f| File.basename(f).match?(/\A(suite|helper|test_helper|for_\w+)\.rb\z/) }
      .select { |f| File.read(repo / f, encoding: "UTF-8").scrub.match?(/def test_|\btest\s+["']|< (Test::Unit::TestCase|Minitest::Test)/) }
    cmds << "for t in #{files.sort.join(' ')}; do bundle exec ruby -Ilib -Itest \"$t\"; done" unless files.empty?
    cmds << "bundle exec rake test" if files.empty? && rake.match?(/task\s*[(:]?\s*:?test\b/)
  end
end
puts cmds.join("; ") unless cmds.empty?
