# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

# libexec/skip_timing.rb: checked runs skip tests that measure time.
class SkipTimingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  TESTS = <<~RUBY
    require "minitest/autorun"
    require "timeout"
    require_relative "lib"
    class T < Minitest::Test
      def test_plain
        assert_equal 1, Foo.new.one
      end

      def test_linear_time
        Timeout.timeout(1) do
          raise "the timing test ran"
        end
      end
    end
  RUBY

  def run_check(env = {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib.rb"), "class Foo; def one = 1; end\n")
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "lib.rbs"), "class Foo\n  def one: () -> Integer\nend\n")
      File.write(File.join(dir, "t.rb"), TESTS)
      Open3.capture2e(env, File.join(ROOT, "exe", "gem-types"), "check", "-s", File.join(dir, "sig"), "-t", "Foo",
                      "--", "ruby", "t.rb", chdir: dir)
    end
  end

  def test_timing_tests_are_skipped
    out, st = run_check
    assert st.success?, out
    assert_match(/2 runs, .* 0 failures, 0 errors, 1 skips/, out)
    assert_includes out, "[gem-types] skipped 1 timing test"
  end

  def test_keep_timing_runs_them
    out, st = run_check("GEM_TYPES_KEEP_TIMING" => "1")
    refute st.success?, out
    assert_includes out, "the timing test ran"
  end
end
