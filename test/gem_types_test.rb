# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/gem_types"

class GemTypesTest < Minitest::Test
  def test_union_collapses_nil_and_empty_generics
    assert_equal "String?", GemTypes.union(%w[String nil])
    assert_equal "(Integer | String)?", GemTypes.union(%w[String Integer nil])
    assert_equal "Array[String]", GemTypes.union(["Array[String]", "Array[untyped]"])
    assert_equal "untyped", GemTypes.union([])
  end

  def test_canonical_treats_optional_and_split_overloads_alike
    assert_equal GemTypes.canonical("(String s) -> Integer?"),
                 GemTypes.canonical("(String) -> Integer | (String) -> nil")
  end

  def test_canonical_ignores_rbs_trace_void
    assert_equal GemTypes.canonical("(?String) -> Netrc"),
                 GemTypes.canonical("(?String) -> void | (?String) -> Netrc")
  end

  def test_evidence_to_rbs
    e = GemTypes::Evidence.new(source: "tracepoint", params: [{ kind: "opt", name: "path", types: ["String"] }],
                               block: %w[no yes], returns: %w[Netrc nil], raises: [], calls: 3)
    assert_equal "(?String path) ?{ (?) -> void } -> Netrc?", e.to_rbs
  end

  def test_return_union_is_parenthesized
    e = GemTypes::Evidence.new(source: "tracepoint", params: [], block: ["no"], returns: %w[String Symbol], calls: 1)
    assert_equal "() -> (String | Symbol)", e.to_rbs
    assert_equal "Array[A | B]", GemTypes.paren("Array[A | B]")
  end

  def test_evidence_self_and_block_passthrough
    e = GemTypes::Evidence.new(source: "tracepoint", params: [], block: ["no"], returns: ["Foo"], calls: 2,
                               self_returns: [2, 2])
    assert_equal "() -> self", e.to_rbs
    e = GemTypes::Evidence.new(source: "tracepoint", params: [], block: %w[no yes], returns: %w[Time Integer], calls: 4,
                               block_passthrough: [2, 2], block_args: [["Time"]], block_self: ["caller"],
                               returns_without_block: ["Time"])
    assert_equal "() -> Time | [T] () { (Time) -> T } -> T", e.to_rbs
    e = GemTypes::Evidence.new(source: "tracepoint", params: [], block: ["yes"], returns: ["Symbol"], calls: 1,
                               block_passthrough: [0, 1], block_self: ["receiver"], block_returns: ["Symbol"])
    assert_equal "() { (?) [self: instance] -> void } -> Symbol", e.to_rbs
  end

  def test_union_drops_test_doubles
    assert_equal "String", GemTypes.union(["String", "RSpec::Mocks::Double"])
  end

  def test_def_index_attrs_and_hidden
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "k.rb"), <<~RUBY)
        module M
          P = Struct.new(:x)
          class K
            attr_accessor :size
            def pub; end
            # @api private
            def internal; end
            private def p1; end
            private
            def priv; end
          end
          module U
            module_function
            def helper; end
          end
        end
      RUBY
      d = GemTypes::DefIndex.new([dir])
      assert_equal({ "M::P#x" => "accessor", "M::K#size" => "accessor" }, d.attrs.transform_values { _1[:kind] })
      assert_equal %w[M::K#internal M::K#p1 M::K#priv M::U#helper].sort, d.hidden.keys.sort
      assert_equal "module_function", d.hidden["M::U#helper"]
      assert_includes d.map { _1[:key] }, "M::U.helper"
    end
  end

  def test_too_wide_member_matching
    anc = { "Foo::Bar" => %w[Foo::Bar Foo::Base Object] }
    assert GemTypes::Verify.satisfies?("Foo::Bar", "Base", "Foo::Thing", anc)
    assert GemTypes::Verify.satisfies?("Integer", "Numeric", "Foo", anc)
    refute GemTypes::Verify.satisfies?("String", "Symbol", "Foo", anc)
    refute GemTypes::Verify.satisfies?("nil", "String", "Foo", anc)
    t = RBS::Parser.parse_type("String? | untyped | bool")
    assert_equal ["String", "nil", :untyped, "bool"], GemTypes::Verify.members(t)
  end

  def test_rbs_reader_reads_methods_attrs_and_aliases
    r = GemTypes::RbsReader.read(<<~RBS)
      module Foo
        class Bar < Baz
          attr_reader name: String
          def self.build: (Integer) -> Bar
          def run: () -> void
          alias go run
        private
          def helper: () -> void
        end
      end
    RBS
    assert_equal({ kind: "class", super: "Baz" }, r.classes["Foo::Bar"])
    assert_equal ["() -> String"], r.methods["Foo::Bar#name"]
    assert_equal ["(Integer) -> Bar"], r.methods["Foo::Bar.build"]
    assert_equal ["(alias of run)"], r.methods["Foo::Bar#go"]
    refute r.methods.key?("Foo::Bar#helper")
  end

  def test_def_index_finds_params_and_return_expressions
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "x.rb"), <<~RUBY)
        module M
          class << self
            def pick(a, b = 1, *rest, k:, &blk)
              if a
                b
              end
            end
          end
        end
      RUBY
      d = GemTypes::DefIndex.new([dir]).first
      assert_equal "M.pick", d[:key]
      assert_equal %w[req opt rest keyreq block], d[:params].map { _1[:kind] }
      assert_equal 1, d[:lasts].size
      assert d[:implicit_nil]
    end
  end

  def test_live_bottomize
    _, _, decls = RBS::Parser.parse_signature(<<~RBS)
      class K
        def initialize: (String) -> void
        def a: (Integer x) { (String) -> void } -> String
        attr_reader b: Integer
      end
    RBS
    io = StringIO.new
    RBS::Writer.new(out: io).write(decls.map { GemTypes::Verify.bottomize(_1) })
    assert_includes io.string, "def initialize: (String) -> void"
    assert_includes io.string, "def a: (Integer x) { (String) -> void } -> bot"
    assert_includes io.string, "attr_reader b: bot"
  end

  def test_def_index_qualified_class_name_inside_module
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        module IPAddress
          class IPAddress::IPv6::Mapped
            def ipv4; end
          end
          class Other::Thing
            def x; end
          end
        end
      RUBY
      keys = GemTypes::DefIndex.new([dir]).map { _1[:key] }
      assert_includes keys, "IPAddress::IPv6::Mapped#ipv4"
      assert_includes keys, "IPAddress::Other::Thing#x"
    end
  end

  def test_def_index_options_hash_and_legacy_constants
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        module L
          class C
            def initialize(args = {}); end
            def add(o) = o.is_a?(Fixnum) ? 1 : 2
          end
        end
      RUBY
      d = GemTypes::DefIndex.new([dir]).to_h { [_1[:key], _1] }
      assert d["L::C#initialize"][:params].first[:hash_default]
      assert_equal ["Fixnum"], d["L::C#add"][:legacy_consts]
      assert_empty d["L::C#initialize"][:legacy_consts]
    end
  end
end
