# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "rbs"
require_relative "../lib/gem_types"
require_relative "../lib/gem_types/repair"

# gem-types repair: value descriptions -> RBS types, widening a slot's
# text, splicing it into the file, and which errors are left alone.
class RepairTest < Minitest::Test
  R = GemTypes::Repair

  def type(desc) = R.rbs_type(desc).first
  def reason(desc) = R.rbs_type(desc).last

  def known(name, **extra) = { "c" => name, "known" => true }.merge(extra.transform_keys(&:to_s))

  def test_maps_core_classes_to_rbs_names
    assert_equal "bool", type(known("TrueClass"))
    assert_equal "bool", type(known("FalseClass"))
    assert_equal "nil", type(known("NilClass"))
    assert_equal "Rake::Task", type(known("Rake::Task"))
    assert_equal "singleton(Rake::Task)", type(known("Class", mod: known("Rake::Task")))
    assert_equal "Enumerator[untyped, untyped]", type(known("Enumerator", tp: 2))
  end

  def test_maps_collections_with_element_types
    assert_equal "Array[Integer | String]", type(known("Array", e: [known("Integer"), known("String")]))
    assert_equal "Array[String?]", type(known("Array", e: [known("String"), known("NilClass")]))
    assert_equal "Array[untyped]", type(known("Array", e: []))
    assert_equal "Array[untyped]", type(known("Array", e: [known("String")], more: true))
    assert_equal "Hash[Symbol, Integer | bool]",
                 type(known("Hash", k: [known("Symbol")], v: [known("Integer"), known("TrueClass"), known("FalseClass")]))
    assert_equal "Hash[untyped, untyped]", type(known("Hash", k: [], v: []))
    assert_equal "Set[String]", type(known("Set", e: [known("String")]))
    assert_equal "Hash[Symbol, untyped]",
                 type(known("Hash", k: [known("Symbol")], v: %w[String Integer Float URI::HTTP].map { known(_1) }))
  end

  def test_skips_values_that_must_not_widen
    assert_match(/anonymous/, reason({ "c" => nil, "anon" => true }))
    assert_match(/test double/, reason(known("RSpec::Mocks::Double")))
    assert_match(/test double/, reason(known("Minitest::Mock")))
    assert_match(/defined by the tests/, reason(known("FakeIO", src: "test/helper.rb")))
    assert_match(/defined by the tests/, reason({ "c" => "MyTask", "src" => "/r/spec/x_spec.rb", "known" => false, "sup" => "Rake::Task" }))
    assert_match(/nearest declared ancestor: Rake::Task/, reason({ "c" => "MyTask", "known" => false, "sup" => "Rake::Task" }))
    assert_match(/no RBS declaration/, reason({ "c" => "Undeclared", "known" => false }))
    assert_match(/placeholder/, reason(known("Object")))
    assert_match(/subclass of Thor/, reason(known("Class", mod: { "c" => nil, "anon" => true, "sup" => "Thor" })))
    assert_match(/element: anonymous/, reason(known("Array", e: [{ "c" => nil, "anon" => true }])))
    assert_match(/defined by the tests/, reason(known("Class", mod: known("Helper", src: "test/a.rb"))))
  end

  def test_widen_unions_the_observed_type
    assert_equal "String | Integer", R.widen("String", ["Integer"])
    assert_equal "(String | Integer)", R.widen("String", ["Integer"], wrap: true)
    assert_equal "String?", R.widen("String", ["nil"])
    assert_equal "(String | IO)?", R.widen("String?", ["IO"])
    assert_equal "(String | IO)?", R.widen("String?", ["IO"], wrap: true)
    assert_equal "Task | String | Symbol", R.widen("Task | String", ["Symbol"])
    assert_equal ":a | :b | :c", R.widen(":a | :b", [":c"])
    assert_equal "(^() -> void) | String", R.widen("^() -> void", ["String"])
  end

  def test_widen_merges_generic_arguments
    assert_equal "Array[String | Integer]", R.widen("Array[String]", ["Array[Integer]"])
    assert_equal "Array[untyped]", R.widen("Array[String]", ["Array[untyped]"])
    assert_equal "Hash[Symbol | String, Integer?]", R.widen("Hash[Symbol, Integer]", ["Hash[String | Symbol, Integer?]"])
    assert_equal "::Array[String | Integer]", R.widen("::Array[String]", ["Array[Integer]"])
    assert_equal "Hash[Symbol, untyped]", R.widen("Hash[Symbol, String | Integer]", ["Hash[Symbol, Float | URI::HTTP]"])
  end

  def test_widen_returns_nil_when_nothing_changes
    assert_nil R.widen("String | Integer", ["Integer"])
    assert_nil R.widen("bool", ["bool"])
    assert_nil R.widen("String?", ["nil"])
    assert_nil R.widen("untyped", ["Integer"])
    assert_nil R.widen("Array[String]", ["Array[String]"])
  end

  def test_literal_values_extend_literal_unions_only
    assert_equal ":c", R.literal_addition(":a | :b", { "c" => "Symbol", "lit" => ":c" })
    assert_nil R.literal_addition("Symbol", { "c" => "Symbol", "lit" => ":c" })
    assert_nil R.literal_addition(":a", { "c" => "Float" })
  end

  def test_absolutize_matches_absolute_style
    assert_equal "::Array[::Foo::Bar | bool] | singleton(::Baz)", R.absolutize("Array[Foo::Bar | bool] | singleton(Baz)")
  end

  def test_splice_keeps_the_rest_of_the_text
    text = "class A\n  # keep me\n  def m: (String x) -> String # trailing\nend\n"
    s = text.index("String")
    e = s + "String".size
    r = text.rindex("String")
    out = R.splice(text, [[s, e, "String | Integer"], [r, r + 6, "(String | Integer)"]])
    assert_equal "class A\n  # keep me\n  def m: (String | Integer x) -> (String | Integer) # trailing\nend\n", out
  end

  def record(file, text, needle, value, outcome: "return", pos: "req", key: "A#m", occurrence: 0)
    s = -1
    (occurrence + 1).times { s = text.index(needle, s + 1) }
    { "key" => key, "kind" => pos == "return" ? "ReturnTypeError" : "ArgumentTypeError",
      "slot" => { "pos" => pos, "index" => 0, "block" => false }, "declared" => needle,
      "loc" => { "file" => file, "start" => s, "end" => s + needle.size },
      "value" => value, "outcome" => outcome, "count" => 2, "frame" => "test/a_test.rb:3" }
  end

  def test_plan_and_apply_widen_only_normal_calls
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rbs")
      text = "class A\n  # doc\n  def m: (String x) -> Integer\n  def n: (Symbol s) -> void\nend\n"
      File.write(file, text)
      recs = [
        record(file, text, "String", known("IO")),
        record(file, text, "String", known("NilClass")),
        record(file, text, "Integer", known("Float"), pos: "return"),
        record(file, text, "Symbol", known("Integer"), outcome: "raise", key: "A#n").merge("exc" => "ArgumentError"),
        record(file, text, "Symbol", { "c" => nil, "anon" => true }, key: "A#n"),
        { "key" => "A#o", "kind" => "UnresolvedOverloadingError", "method_types" => ["(String) -> void", "(Integer) -> void"],
          "args" => [known("Float")], "outcome" => "return", "count" => 1 }
      ]
      plan = R.plan(recs, files: [file], test_file: ->(p) { p.start_with?("test/") })
      assert_equal [["String", "(String | IO)?", 4], ["Integer", "(Integer | Float)", 2]],
                   plan[:changes].map { [_1.old, _1.new, _1.count] }
      assert_equal 3, plan[:changes].first.line
      reasons = plan[:skipped].map { _1[:reason] }
      assert(reasons.any? { _1.include?("raised ArgumentError") })
      assert(reasons.any? { _1.include?("anonymous") })
      assert_equal ["A#o"], plan[:reported].map { _1[:key] }

      applied, deferred, failed = R.apply(plan[:changes])
      assert_equal [2, 0, 0], [applied.size, deferred.size, failed.size]
      assert_equal "class A\n  # doc\n  def m: ((String | IO)? x) -> (Integer | Float)\n  def n: (Symbol s) -> void\nend\n",
                   File.read(file)
    end
  end

  def test_plan_leaves_returns_of_test_defined_receivers
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rbs")
      text = "module DSL\n  def ns: (String x) -> Integer\nend\n"
      File.write(file, text)
      recv = { "c" => "MyTest", "src" => "test/my_test.rb" }
      recs = [record(file, text, "Integer", known("NilClass"), pos: "return").merge("recv" => recv),
              record(file, text, "String", known("Symbol")).merge("recv" => recv)]
      plan = R.plan(recs, files: [file], test_file: ->(p) { p.start_with?("test/") })
      assert_equal [["String", "String | Symbol"]], plan[:changes].map { [_1.old, _1.new] }
      assert_match(/receiver's class MyTest is defined by the tests/, plan[:skipped].first[:reason])
    end
  end

  def test_plan_counts_subclasses_for_an_observed_superclass
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rbs")
      text = "class M\n  def []: (String name) -> void\nend\n"
      File.write(file, text)
      recs = [record(file, text, "String", known("Rake::Task")),
              record(file, text, "String", known("Rake::FileTask", anc: ["Rake::Task"])),
              record(file, text, "String", known("Rake::FileCreationTask", anc: ["Rake::FileTask", "Rake::Task"]))]
      plan = R.plan(recs, files: [file], test_file: ->(_) { false })
      assert_equal [["String | Rake::Task", 6]], plan[:changes].map { [_1.new, _1.count] }
      only_sub = R.plan(recs[1, 1], files: [file], test_file: ->(_) { false })
      assert_equal ["String | Rake::FileTask"], only_sub[:changes].map(&:new)
    end
  end

  def test_plan_refuses_a_slot_whose_text_moved
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rbs")
      text = "class A\n  def m: (String x) -> Integer\nend\n"
      File.write(file, text)
      rec = record(file, text, "String", known("IO"))
      File.write(file, "class A\n  def mm: (String x) -> Integer\nend\n")
      plan = R.plan([rec], files: [file], test_file: ->(_) { false })
      assert_empty plan[:changes]
      assert_match(/changed since the run/, plan[:skipped].first[:reason])
    end
  end

  def test_plan_skips_slots_outside_the_repaired_files
    Dir.mktmpdir do |dir|
      file = File.join(dir, "a.rbs")
      other = File.join(dir, "dep.rbs")
      text = "class A\n  def m: (String x) -> Integer\nend\n"
      File.write(file, text)
      File.write(other, text)
      plan = R.plan([record(other, text, "String", known("IO"))], files: [file], test_file: ->(_) { false })
      assert_empty plan[:changes]
      assert_match(/outside the signatures/, plan[:skipped].first[:reason])
    end
  end

  def test_read_records_merges_processes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.errors.jsonl")
      a = { "key" => "A#m", "kind" => "ReturnTypeError", "count" => 2, "frame" => nil }
      File.write(path, [a, a.merge("count" => 3, "frame" => "t.rb:1")].map { JSON.generate(_1) }.join("\n") + "\n")
      recs = R.read_records(path)
      assert_equal 1, recs.size
      assert_equal 5, recs.first["count"]
      assert_equal "t.rb:1", recs.first["frame"]
    end
  end
end

# End to end: log_errors.rb writes errors.jsonl under `gem-types check -o`,
# and Repair.run widens the fixture's signatures from it.
class RepairRunTest < Minitest::Test
  FIX = File.expand_path("fixtures/repair", __dir__)

  def test_repair_widens_from_a_checked_run
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir[File.join(FIX, "*")], dir)
      out = File.join(dir, "evidence")
      cfg = GemTypes::Config.new(repo: dir, lib_dirs: ["."], test_dirs: ["test"], ns: ["Shelf"], requires: ["lib"],
                                 test_cmd: "ruby test/shelf_test.rb", env: {}, out: out)
      sig = File.join(dir, "sig")
      report = GemTypes::Repair.run(cfg, sig, [cfg.test_cmd], io: StringIO.new)
      rbs = File.read(File.join(sig, "shelf.rbs"))
      assert_includes rbs, "  # Items are strings (deliberately too narrow for the test below).\n"
      assert_includes rbs, "def add: (String | Symbol item) -> self"
      assert_includes rbs, "def first: () -> (String | Symbol)"
      assert_includes rbs, "def check: (String x) -> String", "a call that raised must not widen"
      assert_includes rbs, "| (Integer) -> Integer\n", "overloads are reported, not changed"
      reasons = report[:skipped].map { _1[:reason] }.join("\n")
      assert_match(/Helper is defined by the tests/, reasons)
      assert_match(/anonymous class/, reasons)
      assert_match(/raised ArgumentError/, reasons)
      assert_equal ["Shelf#pick"], report[:reported].map { _1[:key] }
      saved = JSON.parse(File.read(File.join(out, "repair.json")))
      assert_equal 2, saved["changes"].size
      jsonl = File.readlines(File.join(out, "repair", "round1-0.errors.jsonl")).map { JSON.parse(_1) }
      add = jsonl.find { _1["key"] == "Shelf#add" && _1.dig("value", "c") == "Symbol" }
      assert_equal({ "pos" => "req", "index" => 0, "name" => "item", "block" => false }, add["slot"])
      assert_equal "::String", add["declared"]
      assert_equal "return", add["outcome"]
      assert_match(%r{test/shelf_test\.rb:4}, add["frame"])
    end
  end
end
