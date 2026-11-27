# Prints a likely command to run a gem's own test suite, from its layout.
# When a repo has both spec/ and test/, both are run.
#
# Usage: ruby detect_test_cmd.rb <repo dir> <env Gemfile>
require "pathname"
require "shellwords"
repo = Pathname(ARGV[0])
gemfile = File.exist?(ARGV[1].to_s) ? File.read(ARGV[1]) : ""
rakefile = %w[Rakefile rakefile Rakefile.rb].map { repo / _1 }.find(&:file?)
rake = rakefile ? rakefile.read : ""
has = ->(g) { gemfile.match?(/^\s*gem\s+["']#{Regexp.escape(g)}["']/) }
rake_task = ->(t) { rake.match?(/task\s*[(:]?\s*:?["']?#{t}\b/) }
# Runs each file on its own (the shell has no ** glob: list them).
each_file = ->(files) { "for t in #{files.sort.map(&:shellescape).join(' ')}; do bundle exec ruby -Ilib -Itest \"$t\"; done" }

cmds = []
if (repo / "spec").directory?
  rspec = has.("rspec") || has.("rspec-core") || (repo / ".rspec").file?
  helpers = Dir.chdir(repo) { Dir["spec/{spec_helper,helper}.rb"] }.map { (repo / _1).read.scrub }.join("\n")
  # minitest/spec under spec/ (launchy): the files run with ruby.
  minitest_spec = helpers.match?(/require\s*\(?\s*["']minitest/) && !helpers.match?(/require\s*\(?\s*["']rspec/)
  specs = Dir.chdir(repo) { Dir["spec/**/*_spec.rb"] }
  if minitest_spec && !specs.empty?
    cmds << each_file.(specs).sub("-Itest", "-Ispec")
  elsif rspec
    cmds << "bundle exec rspec"
  elsif rake_task.("spec")
    # spec/ without RSpec (bacon, minitest/spec, ...): the Rakefile knows.
    cmds << "bundle exec rake spec"
  elsif !(repo / "test").directory?
    cmds << "bundle exec rspec"
  end
end
if (repo / "test").directory?
  named = Dir.chdir(repo) { Dir["test/**/{*_test,test_*}.rb"] }
  if (rake.match?(/TestTask/) || rake_task.("test")) && !named.empty?
    cmds << "bundle exec rake test"
  elsif !named.empty?
    cmds << each_file.(named)
  else
    # test/unit/*.rb style without the usual names (e.g. coderay): run
    # every file under test/unit and test/functional that defines tests.
    files = Dir.chdir(repo) { Dir["test/{unit,functional}/*.rb"] }
      .reject { |f| File.basename(f).match?(/\A(suite|helper|test_helper|for_\w+)\.rb\z/) }
      .select { |f| File.read(repo / f, encoding: "UTF-8").scrub.match?(/def test_|\btest\s+["']|< (Test::Unit::TestCase|Minitest::Test)/) }
    cmds << each_file.(files) unless files.empty?
    cmds << "bundle exec rake test" if files.empty? && rake_task.("test")
  end
end
# A Rakefile that defines the test task only under Appraisal or CI (jbuilder:
# `if !ENV["APPRAISAL_INITIALIZED"] && !ENV["CI"]` makes appraisal the
# default): set CI so `rake test` exists.
if rake.match?(/Appraisal::Task/) && rake.match?(/ENV\[["']CI["']\]/)
  cmds = cmds.map { |c| c.start_with?("bundle exec rake") ? "CI=1 #{c}" : c }
end
puts cmds.join("; ") unless cmds.empty?
