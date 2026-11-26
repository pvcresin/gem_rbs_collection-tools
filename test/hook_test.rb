# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

# rbs/test's generated wrappers, as fixed by libexec/rbs_hook_fix.rb:
# BasicObject subclasses can be checked, and blocks keep their arity.
class HookTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIX = File.join(ROOT, "test", "fixtures", "hook")

  def check(rbs)
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[File.join(FIX, "*.rb")], dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "lib.rbs"), rbs)
      Open3.capture2e(File.join(ROOT, "exe", "gem-types"), "check", "-s", File.join(dir, "sig"), "-t", "Tag,Disp",
                      "--", "ruby", "run.rb", chdir: dir)
    end
  end

  def test_basic_object_and_block_arity
    out, st = check(File.read(File.join(FIX, "lib.rbs")))
    assert st.success?, out
    assert_includes out, %("<a><b>")
    assert_includes out, "[1, 2]\n1\n", "a two-parameter block must be seen with arity 2"
    assert_includes out, "true", "a lambda block must stay a lambda"
  end

  def test_basic_object_types_are_checked
    out, = check(File.read(File.join(FIX, "lib.rbs")).sub("?{ (Tag) -> void } -> String", "?{ (Tag) -> void } -> Integer"))
    assert_match(/\[Tag#tag!\] ReturnTypeError/, out)
  end
end
