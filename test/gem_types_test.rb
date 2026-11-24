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
    assert_equal "(?String path) ?{ (?) -> untyped } -> Netrc?", e.to_rbs
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
end
