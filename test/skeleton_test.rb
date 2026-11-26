# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/gem_types"

# The draft's structure follows the def: each case drafts from evidence
# with a structural mistake and checks the corrected declaration, and that
# `gem-types lint` finds nothing in the draft.
class SkeletonTest < Minitest::Test
  Config = Struct.new(:ns, :lib_paths) do
    def in_ns?(key) = ns.any? { |n| key.start_with?("#{n}#", "#{n}.", "#{n}::") }
  end

  # [draft text, lint findings on it]. evidence: { key => signature }.
  def draft(ruby, evidence, classes: {}, source: "typeprof")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), ruby)
      defs = GemTypes::DefIndex.new([dir])
      ev = { source => evidence.transform_values { |s| GemTypes::Evidence.new(source: source, sigs: [s]) } }
      text = GemTypes::Merger.new(evidence: ev, defs: defs, classes: classes).draft
      sig = File.join(dir, "a.rbs")
      File.write(sig, text)
      parsed = GemTypes::Verify.parse_sigs(sig)
      found = GemTypes::Lint.run(Config.new(%w[A], [dir]), parsed, defs).map { |k, m| "#{k}: #{m}" }
      [text, found]
    end
  end

  def decl(text, name) = text[/^\s*def #{Regexp.escape(name)}: .*$/]&.strip

  def assert_decl(expected, text, name)
    assert_equal expected, decl(text, name), text
  end

  def test_parameters_follow_the_def_and_keep_types_by_name
    text, found = draft(<<~RUBY, { "A#m" => "(String a, Integer b, Symbol c) -> String", "A#n" => "(*untyped) -> untyped" })
      class A
        def m(a, b = 1, *rest, c)
          a
        end
        def n(x, (y, z))
          x
        end
      end
    RUBY
    assert_decl "def m: (String a, ?Integer b, *untyped rest, Symbol c) -> String", text, "m"
    assert_decl "def n: (untyped x, untyped) -> untyped", text, "n"
    assert_match(/structure: parameters from the def/, text)
    assert_empty found
  end

  def test_overloads_that_narrow_the_arity_are_kept
    text, = draft(<<~RUBY, { "A#m" => "(String a) -> String | (String a, Integer b) -> Integer" })
      class A
        def m(a, b = nil) = a
      end
    RUBY
    assert_decl "def m: (String a) -> String | (String a, Integer b) -> Integer", text, "m"
  end

  def test_a_default_is_optional_and_a_missing_argument_is_added
    text, found = draft(<<~RUBY, { "A#reload" => "(bool force) -> bool", "A#x=" => "() -> void" })
      class A
        def reload(force = false) = force
        def x=(v)
          @x = v
        end
      end
    RUBY
    assert_decl "def reload: (?bool force) -> bool", text, "reload"
    assert_decl "def x=: (untyped v) -> void", text, "x="
    assert_empty found
  end

  def test_keywords_follow_the_def
    text, found = draft(<<~RUBY, { "A#m" => "(?verbose: bool, ?extra: Integer) -> nil", "A#k" => "(?a: String) -> nil", "A#h" => "(String name, ?verbose: bool, **untyped) -> nil" })
      class A
        def m(force:, verbose: false)
          nil
        end
        def k(a: 1, **opts)
          nil
        end
        def h(name, config = {})
          nil
        end
      end
    RUBY
    assert_decl "def m: (force: untyped, ?verbose: bool) -> nil", text, "m"
    assert_decl "def k: (?a: String, **untyped opts) -> nil", text, "k"
    # A def without keywords keeps named keywords (an options Hash) but
    # not `**untyped`.
    assert_decl "def h: (String name, ?untyped config, ?verbose: bool) -> nil", text, "h"
    assert_empty found
  end

  def test_keywords_named_like_positional_parameters_are_dropped
    text, = draft(<<~RUBY, { "A.new" => "(?untyped name, ?untyped usage) -> instance | (?name: untyped, ?usage: untyped) -> instance" })
      class A
        def initialize(name, usage = nil); end
      end
    RUBY
    assert_decl "def self.new: (untyped name, ?untyped usage) -> instance", text, "self.new"
  end

  def test_block_removed_when_the_source_takes_none
    text, found = draft(<<~RUBY, { "A#text!" => "(String text) { (?) -> untyped } -> self", "A#child" => "() { () -> void } -> void" })
      class A
        def text!(text)
          self
        end
      end
      class B
        def child; end
      end
      class C < B
        def child(x = nil)
          super()
        end
      end
    RUBY
    assert_decl "def text!: (String text) -> self", text, "text!"
    assert_match(/no block \(the source neither yields nor takes one\)/, text)
    assert_empty found
  end

  def test_block_added_required_or_optional
    ev = { "A#each_pair" => "() -> void", "A#maybe" => "() -> void", "A#on" => "() -> void", "A#pass" => "() -> void" }
    text, found = draft(<<~RUBY, ev)
      class A
        def each_pair
          @h.each { |k, v| yield k, v }
        end
        def maybe
          yield 1 if block_given?
        end
        def on(&blk)
          @cb = blk
        end
        def pass(&blk)
          @list.each(&blk)
        end
      end
    RUBY
    assert_decl "def each_pair: () { (untyped, untyped) -> untyped } -> void", text, "each_pair"
    assert_decl "def maybe: () ?{ (untyped) -> untyped } -> void", text, "maybe"
    assert_decl "def on: () { (?) -> untyped } -> void", text, "on"
    assert_decl "def pass: () ?{ (?) -> untyped } -> void", text, "pass"
    assert_empty found
  end

  def test_required_block_made_optional_when_guarded_or_only_passed_on
    text, found = draft(<<~RUBY, { "A#read" => "(untyped x) { (untyped) -> void } -> untyped", "A#uniq!" => "() { (?) -> untyped } -> self?" })
      class A
        def read(x)
          yield x if block_given?
        end
        def uniq!(&block)
          self if @keys.uniq!(&block)
        end
      end
    RUBY
    assert_decl "def read: (untyped x) ?{ (untyped) -> void } -> untyped", text, "read"
    assert_decl "def uniq!: () ?{ (?) -> untyped } -> self?", text, "uniq!"
    assert_match(/only passes it on: check the callee/, text)
    assert_empty found
  end

  def test_enumerator_overload_when_the_source_returns_to_enum
    text, found = draft(<<~RUBY, { "A#each" => "() ?{ (String) -> void } -> (Enumerator[String, self] | self)" })
      class A
        def each
          return to_enum(:each) unless block_given?
          @items.each { |x| yield x }
          self
        end
      end
    RUBY
    assert_decl "def each: () { (String) -> void } -> self | () -> Enumerator[String, self]", text, "each"
    assert_empty found
  end

  def test_block_parameter_count_from_yield
    text, found = draft(<<~RUBY, { "A#with" => "[T] () { (?) -> T } -> T", "A#pairs" => "() { ([String, Integer]) -> void } -> void", "A#one" => "() { (String a, Integer b) -> void } -> void" })
      class A
        def with
          yield
        end
        def pairs
          @h.each { |k, v| yield k, v }
        end
        def one
          @h.each { |pair| yield pair }
        end
      end
    RUBY
    assert_decl "def with: [T] () { () -> T } -> T", text, "with"
    assert_decl "def pairs: () { ([ String, Integer ], untyped) -> void } -> void", text, "pairs"
    # One yielded Array destructures into |a, b|: kept.
    assert_decl "def one: () { (String a, Integer b) -> void } -> void", text, "one"
    assert_empty found
  end

  def test_block_self_type_for_instance_eval_and_not_for_yield
    ev = { "A#configure" => "() { () -> void } -> void", "A#build" => "() { () -> void } -> void",
           "A#verbose" => "() { () [self: instance] -> void } -> void" }
    text, found = draft(<<~RUBY, ev)
      class A
        def configure(&block) = instance_eval(&block)
        def build(&block)
          Builder.new.instance_exec(&block)
        end
        def verbose
          yield
        end
      end
    RUBY
    assert_decl "def configure: () { () [self: self] -> void } -> void", text, "configure"
    assert_decl "def build: () { () [self: Builder] -> void } -> void", text, "build"
    assert_decl "def verbose: () { () -> void } -> void", text, "verbose"
    assert_match(/block self `self` guessed/, text)
    assert_empty found
  end

  def test_nil_added_when_the_source_can_return_nil
    ev = { "A#find" => "(String k) -> String", "A#opt" => "() -> (String | Integer)", "A#ok" => "() -> String?", "A#name=" => "(String v) -> String" }
    text, found = draft(<<~RUBY, ev)
      class A
        def find(k)
          return if k.empty?
          k
        end
        def opt
          if @a
            "x"
          elsif @b
            1
          end
        end
        def ok
          return nil if @x
          "y"
        end
        def name=(v)
          return unless v
          @name = v
        end
      end
    RUBY
    assert_decl "def find: (String k) -> String?", text, "find"
    assert_decl "def opt: () -> (String | Integer)?", text, "opt"
    assert_decl "def ok: () -> String?", text, "ok"
    assert_decl "def name=: (String v) -> String", text, "name="
    assert_match(/find: .*\n.*/, text)
    assert_match(/returns nil \(`return`\/`nil` in the source\)/, text)
    assert_match(/`if`\/`case` without `else`.*exhaustive/, text)
    assert_empty found
  end

  def test_module_function_is_self_question
    text, found = draft(<<~RUBY, { "A.helper" => "(String s) -> String" })
      module A
        module_function

        def helper(s) = s
      end
    RUBY
    assert_decl "def self?.helper: (String s) -> String", text, "self?.helper"
    assert_empty found
  end

  def test_privatized_mixin_methods_are_private
    text, found = draft(<<~RUBY, { "A::DSL#task" => "(Symbol name) -> void", "A::DSL#sh" => "(*String cmd) -> bool", "A::Ext#verbose" => "(?bool v) -> bool" }, classes: { "A::DSL" => { kind: "module" } })
      module A
        module Ext
          def verbose(v = nil) = v
          def touch(file); end
          private def secret; end
        end
        module DSL
          include Ext
          private(*Ext.instance_methods(false))
          def task(name); end
        end
      end
      module Ext; end
    RUBY
    dsl = text[/^module A::DSL\n.*?^end/m]
    assert_match(/def task: \(Symbol name\) -> void\n\n  private\n/, dsl)
    assert_match(/^  def touch: \(untyped file\) -> untyped$/, dsl)
    assert_match(/^  def verbose: \(\?bool v\) -> bool$/, dsl)
    refute_match(/secret/, dsl)
    assert_empty found
  end

  def test_inherited_initialize_gives_new_its_parameters
    text, = draft(<<~RUBY, { "A::Sub.new" => "(*String args) -> untyped" }, classes: { "A::Sub" => { kind: "class", super: "A::Base" } })
      module A
        class Base
          def initialize(prompt, options); end
        end
        class Sub < Base; end
      end
    RUBY
    # The rest type of the evidence spreads over the def's parameters.
    assert_decl "def self.new: (String prompt, String options) -> untyped", text, "self.new"
  end

  def test_def_index_shape_and_super_forwarding
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        class A
          def a(*, **, &) = b(*, **, &)
          def f(...) = g(...)
          def n(x, **nil) = x
          def s(x)
            super(x)
          end
        end
      RUBY
      defs = GemTypes::DefIndex.new([dir]).to_h { |d| [d[:key], d] }
      assert_equal %w[rest keyrest block], defs["A#a"][:shape].map { _1[:kind] }
      assert_equal [nil, nil, nil], defs["A#a"][:shape].map { _1[:name] }
      assert_equal %w[fwd], defs["A#f"][:shape].map { _1[:kind] }
      assert_equal %w[req nokey], defs["A#n"][:shape].map { _1[:kind] }
      assert defs["A#s"][:block][:forwarded]
    end
  end

  def test_signature_left_alone_when_it_already_fits
    text, = draft(<<~RUBY, { "A#each" => "() ?{ (String) -> void } -> self", "A#x" => "() -> Integer" })
      class A
        def each
          @a.each { |v| yield v } if block_given?
          self
        end
        def x = 1
      end
    RUBY
    refute_match(/structure:/, text)
  end
end
