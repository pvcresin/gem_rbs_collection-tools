# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"
require_relative "../lib/gem_types"

class MsgCheckTest < Minitest::Test
  RBS = <<~RBS
    module Zz
      class Client
        def initialize: () -> void
        def get: (String key) -> untyped
        def set: (String key, untyped value) -> bool
        def alive?: () -> bool
        def delete: (String key) -> void
      end
    end
  RBS

  def with_sig
    Dir.mktmpdir do |dir|
      sig = File.join(dir, "gems", "zz", "1.2")
      FileUtils.mkdir_p(sig)
      File.write(File.join(sig, "zz.rbs"), RBS)
      yield dir, sig
    end
  end

  def msg(body)
    "Add RBS for zz 1.2\n\n#{body}\n\n## Verification\n\n- ok\n\n## References\n\n- https://example.com/zz/tree/v1.2.0\n"
  end

  def levels(found) = found.map(&:first).tally

  def test_clean_message_passes
    with_sig do |_, sig|
      found = GemTypes::MsgCheck.run(msg("Zz::Client: new, get, set, delete and alive?."), sig: sig, gem: "zz")
      assert_empty found
    end
  end

  def test_format_and_mangled_characters_are_errors
    with_sig do |_, sig|
      text = "Add RBS for zz 1.3\nno blank line\nA &amp; B — Co-Authored-By: x\n"
      errors = GemTypes::MsgCheck.run(text, sig: sig, gem: "zz").select { _1.first == :error }.map(&:last)
      assert(errors.any? { _1.include?("version 1.3") })
      assert(errors.any? { _1.include?("second line") })
      assert(errors.any? { _1.include?("non-ASCII") })
      assert(errors.any? { _1.include?("HTML entity") })
      assert(errors.any? { _1.include?("Co-Authored-By") })
      assert(errors.any? { _1.include?("## Verification") })
    end
  end

  def test_names_not_in_the_rbs_are_flagged
    with_sig do |_, sig|
      found = GemTypes::MsgCheck.run(msg("Zz::Client (get, set, delete, prepare) and cloud_run? and Zz::Client#fetch."), sig: sig, gem: "zz")
      warns = found.map(&:last)
      assert(warns.any? { _1.start_with?("prepare ") })
      assert(warns.any? { _1.start_with?("cloud_run? ") })
      assert(warns.any? { _1.start_with?("Zz::Client#fetch ") })
      refute(warns.any? { _1.start_with?("get ") })
    end
  end

  def test_numbers_must_match_verify_and_live
    with_sig do |dir, sig|
      w = File.join(dir, "w")
      FileUtils.mkdir_p(File.join(w, "evidence"))
      File.write(File.join(w, "evidence", "verify.json"), JSON.generate(checked: { total: 10 }, checks: 99))
      File.write(File.join(w, "evidence", "live.json"), JSON.generate(checked: %w[a b c], unchecked: ["d"]))
      text = msg("- Called every method: 3/4 declarations fail.\n- Suite: 10 examples,\n  98 type checks.")
      errors = GemTypes::MsgCheck.run(text, sig: sig, gem: "zz", workdir: w).select { _1.first == :error }.map(&:last)
      assert_equal ["the message says 98 type checks, verify.json has 99"], errors
    end
  end
end

class ShipTest < Minitest::Test
  def repo
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir, exception: true)
      system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init", exception: true)
      system("git", "-C", dir, "checkout", "-q", "-b", "add-zz", exception: true)
      sig = File.join(dir, "gems", "zz", "1.2")
      FileUtils.mkdir_p(sig)
      File.write(File.join(sig, "zz.rbs"), "module Zz\n  def self.get: () -> String\nend\n")
      yield dir, sig
    end
  end

  def test_refuses_changes_outside_the_gem
    repo do |dir, sig|
      File.write(File.join(dir, "README.md"), "x")
      File.write(File.join(dir, "msg"), "Add RBS for zz 1.2\n\nZz.get.\n\n## Verification\n\n## References\n")
      out = StringIO.new
      refute GemTypes::Ship.run(workdir: dir, sig: sig, msg: File.join(dir, "msg"), out: out)
      assert_match(/FAIL  only gems\/zz\/ changed: other changes: README.md/, out.string)
    end
  end

  def test_stops_on_message_errors_before_running_anything
    repo do |dir, sig|
      msg = File.join(dir, "..", "msg-#{File.basename(dir)}")
      File.write(msg, "Add RBS for zz 1.3\n\nZz.get — done.\n")
      out = StringIO.new
      refute GemTypes::Ship.run(workdir: dir, sig: sig, msg: msg, out: out)
      assert_match(/FAIL  msg-check/, out.string)
      refute_match(/bin\/test/, out.string)
    ensure
      File.delete(msg) if msg && File.exist?(msg)
    end
  end
end
