# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/gem_types"

# Each case is a mistake later fixed in gem_rbs_collection's history.
class LintTest < Minitest::Test
  Config = Struct.new(:ns) do
    def in_ns?(key) = ns.any? { |n| key.start_with?("#{n}#", "#{n}.", "#{n}::") }
  end

  def lint(ruby, rbs, ns: %w[A])
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), ruby)
      sig = File.join(dir, "a.rbs")
      File.write(sig, rbs)
      parsed = GemTypes::Verify.parse_sigs(sig)
      GemTypes::Lint.run(Config.new(ns), parsed, GemTypes::DefIndex.new([dir])).map { |k, m| "#{k}: #{m}" }
    end
  end

  def assert_finds(pattern, found) = assert(found.any? { _1.match?(pattern) }, "expected #{pattern.inspect} in #{found.inspect}")

  def test_required_block_that_the_source_guards
    found = lint(<<~RUBY, <<~RBS)
      class A
        def each
          return to_enum(:each) unless block_given?
          yield 1
        end
        def read(x)
          yield x if block_given?
        end
      end
    RUBY
      class A
        def each: () { (Integer) -> void } -> void
        def read: (untyped x) { (untyped) -> untyped } -> untyped
      end
    RBS
    assert_finds(/A#each: the block is optional .*Enumerator/, found)
    assert_finds(/A#read: the block is optional/, found)
  end

  def test_block_not_declared_and_yield_arity
    found = lint(<<~RUBY, <<~RBS)
      class A
        def run(&blk) = @cb = blk
        def pairs
          @h.each { |k, v| yield k, v }
        end
      end
    RUBY
      class A
        def run: () -> void
        def pairs: () { ([String, Integer]) -> void } -> void
      end
    RBS
    assert_finds(/A#run: the source takes a block/, found)
    assert_finds(/A#pairs: the source yields 2 arguments/, found)
  end

  def test_dsl_block_needs_self_type
    found = lint(<<~RUBY, <<~RBS)
      class A
        def configure(&block) = instance_eval(&block)
      end
    RUBY
      class A
        def configure: () { () -> void } -> void
      end
    RBS
    assert_finds(/self: X/, found)
  end

  def test_arity_and_keywords
    found = lint(<<~RUBY, <<~RBS)
      class A
        def reload(force = false) = force
        def find(id, *rest) = id
        def get(url, timeout: 1, retries: 2) = url
        def name=(v) = @n = v
      end
    RUBY
      class A
        def reload: (bool force) -> bool
        def find: () -> untyped
        def get: (String url, ?timeout: Integer) -> String
        def name=: (String v, Integer x) -> String
      end
    RBS
    assert_finds(/A#reload: every overload requires 1/, found)
    assert_finds(/A#get: keyword `retries:` not declared/, found)
    assert_finds(/A#name=: a setter takes exactly one/, found)
  end

  def test_nil_return
    found = lint(<<~RUBY, <<~RBS)
      class A
        def first
          return nil if @items.empty?
          @items[0]
        end
        def label
          "x" if @on
        end
      end
    RUBY
      class A
        def first: () -> String
        def label: () -> String
      end
    RBS
    assert_finds(/A#first: the source returns nil/, found)
    assert_finds(/A#label: the source can end without a value/, found)
  end

  def test_rbs_only_mistakes
    found = lint(<<~RUBY, <<~RBS)
      module A
        def persisted? = false
        class B
          def ==(other) = true
          def hash = 1
          def each = yield(1)
          def check = yield(1)
        end
      end
    RUBY
      module A
        VERSION: "1.2.3"
        def persisted?: () -> false
        class B
          def ==: (untyped other) -> untyped
          def hash: () -> String
          def check: () { (Integer) -> bool } -> void
          def gone?: () -> true
        end
      end
    RBS
    assert_finds(/A::VERSION: typed as the literal/, found)
    assert_finds(/A#persisted\?: returns the literal false, but it is a module's instance method/, found)
    assert_finds(/A::B#hash: returns String; hash is expected to return Integer/, found)
    assert_finds(/A::B#check: block returns bool/, found)
    assert_finds(/A::B#gone\?: returns the literal type true/, found)
    refute(found.any? { _1.start_with?("A::B#==") }, "untyped is not flagged as a wrong protocol type")
  end

  def test_module_function_needs_self_q
    found = lint(<<~RUBY, <<~RBS)
      module A
        module_function
        def width = 80
      end
    RUBY
      module A
        def self.width: () -> Integer
      end
    RBS
    assert_finds(/A.width: module_function: declare it `def self\?.width`/, found)
  end

  def test_no_findings_for_matching_rbs
    found = lint(<<~RUBY, <<~RBS)
      class A
        def each
          return to_enum(:each) unless block_given?
          yield 1, 2
          self
        end
        def get(url, timeout: 1) = url
        def ok? = @ok == 1
      end
    RUBY
      class A
        def each: () { (Integer, Integer) -> void } -> self
                | () -> Enumerator[[Integer, Integer], self]
        def get: (String url, ?timeout: Integer) -> String
        def ok?: () -> bool
      end
    RBS
    assert_equal [], found
  end

  def test_layout_and_manifest
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "_test"))
      File.write(File.join(dir, "_test", "test.rb"), "# Write Ruby code to test the RBS.\nA.new.go\n")
      File.write(File.join(dir, "manifest.yaml"), "dependencies:\n  - name: faraday\n  - monitor\n")
      File.write(File.join(dir, "a.rbs"), "class A\n  def go: (URI::Generic u) -> Logger\nend\n")
      found = GemTypes::Lint.layout(dir).map { |k, m| "#{k}: #{m}" }
      assert_finds(/no `# @type var/, found)
      assert_finds(/header comment/, found)
      assert_finds(/faraday is not a library in rbs's stdlib/, found)
      assert_finds(/entry "monitor" must be `- name:/, found)
      assert_finds(/uses URI \(uri\)/, found)
      assert_finds(/uses Logger \(logger\)/, found)
    end
  end

  def test_rest_args_with_a_default_are_optional
    found = lint(<<~RUBY, <<~RBS)
      class A
        def create_file(dest, *args, &block)
          config = args.last.is_a?(Hash) ? args.pop : {}
          data = args.first
          [dest, block || data.to_s, config]
        end
        def insert(dest, *args, &block)
          data = block_given? ? block : args.shift
          config = args.shift || {}
          [dest, data, config]
        end
      end
    RUBY
      class A
        def create_file: (String dest, String data) -> untyped
                       | (String dest) { () -> String } -> untyped
        def insert: (String dest, String data) -> untyped
                  | (String dest) { () -> String } -> untyped
      end
    RBS
    assert_finds(/A#create_file: without a block, every overload requires 2/, found)
    refute(found.any? { _1.start_with?("A#insert:") }, found.inspect)
  end

  def test_privatized_mixin_methods
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        module Tools
          def run(x) = x
        end
        module A
          include Tools
          private(*Tools.instance_methods(false))
        end
      RUBY
      sig = File.join(dir, "a.rbs")
      File.write(sig, "module Tools\n  def run: (String x) -> String\nend\nmodule A\n  include Tools\nend\n")
      cfg = Struct.new(:ns, :lib_paths) { def in_ns?(k) = ns.any? { |n| k.start_with?(n) } }.new(%w[A Tools], [dir])
      found = GemTypes::Lint.run(cfg, GemTypes::Verify.parse_sigs(sig), GemTypes::DefIndex.new([dir])).map { |k, m| "#{k}: #{m}" }
      assert_finds(/A: makes Tools's methods private .* run public/, found)
      File.write(sig, "module Tools\n  def run: (String x) -> String\nend\nmodule A\n  include Tools\n  private\n  def run: (String x) -> String\nend\n")
      found = GemTypes::Lint.run(cfg, GemTypes::Verify.parse_sigs(sig), GemTypes::DefIndex.new([dir])).map { |k, m| "#{k}: #{m}" }
      refute(found.any? { _1.include?("makes Tools") }, found.inspect)
    end
  end
end
