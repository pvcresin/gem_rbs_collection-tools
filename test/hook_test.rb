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

  def check(rbs, env = {})
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[File.join(FIX, "*.rb")], dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "lib.rbs"), rbs)
      Open3.capture2e(env, File.join(ROOT, "exe", "gem-types"), "check", "-s", File.join(dir, "sig"), "-t", "Tag,Disp,Pre,Named,Stream",
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

  # RBS_TEST_RAW_BLOCKS: a method that keeps its block gets the caller's
  # block itself, so identity comparisons hold.
  def test_raw_blocks_keep_identity
    out, st = check(File.read(File.join(FIX, "lib.rbs")))
    assert st.success?, out
    assert_includes out, "kept_same=false"
    out, st = check(File.read(File.join(FIX, "lib.rbs")), "RBS_TEST_RAW_BLOCKS" => "Disp#keep")
    assert st.success?, out
    assert_includes out, "kept_same=true"
  end

  # A class that prepends wrappers of its own methods (Addressable::URI's
  # RestoreOnFailure): the hook must not recurse, and must still check.
  def test_prepended_wrappers
    out, st = check(File.read(File.join(FIX, "lib.rbs")))
    assert st.success?, out
    assert_includes out, "pre=x,true"
    out, = check(File.read(File.join(FIX, "lib.rbs")).sub("def name=: (String v) -> String", "def name=: (Integer v) -> String"))
    assert_match(/\[Pre#name=\] ArgumentTypeError/, out)
  end

  # Module#name overridden to return a Symbol: the class is still hooked.
  def test_classes_with_their_own_name_are_checked
    out, = check(File.read(File.join(FIX, "lib.rbs")).sub("def value: () -> Integer", "def value: () -> String"))
    assert_match(/Named#value\] ReturnTypeError/, out)
  end

  # A returned Enumerator of unknown size is not iterated by the check: it
  # may read a stream the caller has not read yet.
  def test_unsized_enumerators_are_not_consumed
    out, st = check(File.read(File.join(FIX, "lib.rbs")))
    assert st.success?, out
    assert_includes out, "stream_rest=2,2"
  end

  # The original and wrapper aliases rbs/test adds are private: specs that
  # list a class's public methods must not see them.
  def test_hook_aliases_are_private
    out, st = check(File.read(File.join(FIX, "lib.rbs")))
    assert st.success?, out
    assert_includes out, "pub=keep,kept,lam?,run\n"
  end

  def test_basic_object_types_are_checked
    out, = check(File.read(File.join(FIX, "lib.rbs")).sub("?{ (Tag) -> void } -> String", "?{ (Tag) -> void } -> Integer"))
    assert_match(/\[Tag#tag!\] ReturnTypeError/, out)
  end

  # Methods added outside the class body (`class << Foo`), Struct.new
  # classes and private singleton methods are hooked too.
  def test_methods_rbs_test_alone_misses
    fix = File.join(ROOT, "test", "fixtures", "hook2")
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[File.join(fix, "*.rb")], dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      FileUtils.cp(File.join(fix, "lib.rbs"), File.join(dir, "sig"))
      Open3.capture2e(File.join(ROOT, "exe", "gem-types"), "check", "-s", File.join(dir, "sig"), "-t", "Reg::Types,Cache",
                      "-o", File.join(dir, "out"), "--", "ruby", "run.rb", chdir: dir)
      errors = File.read(File.join(dir, "out.errors.tsv"))
      %w[Reg::Types.pub Reg::Types.lazy? Cache.load Cache#version Reg::Types.secret].each do |key|
        assert_includes errors, "[#{key}]"
      end
    end
  end
end
