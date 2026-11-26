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

  # --- --fix ---

  # Runs Lint.run, applies the fixes and returns [new RBS, applied keys,
  # findings left after the fixes].
  def fix(ruby, rbs, ns: %w[A], lib: false)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), ruby)
      sig = File.join(dir, "a.rbs")
      File.write(sig, rbs)
      cfg = Struct.new(:ns, :lib_paths) { def in_ns?(k) = ns.any? { |n| k.start_with?("#{n}#", "#{n}.", "#{n}::") } }.new(ns, lib ? [dir] : [])
      run = -> { GemTypes::Lint.run(cfg, GemTypes::Verify.parse_sigs(sig), GemTypes::DefIndex.new([dir])) }
      res = GemTypes::Lint.apply_fixes(run.())
      assert_equal [], res[:failed]
      out = File.read(sig)
      GemTypes::Verify.parse_sigs(sig)
      [out, res[:applied].map { |f, _| f.key }, run.().map { |k, m| "#{k}: #{m}" }]
    end
  end

  def test_fix_optional_block_and_enumerator_overload
    out, applied, left = fix(<<~RUBY, <<~RBS)
      class A
        def each
          return to_enum(:each) unless block_given?
          yield 1, 2
          self
        end
        def read(x)
          yield x if block_given?
        end
        def drop!(&block)
          return @keys.reject! unless block
          self if @keys.reject!(&block)
        end
      end
    RUBY
      class A
        # Yields pairs.
        def each: () { (Integer, Integer) -> void } -> self
        def read: (untyped x) { (untyped) -> untyped } -> untyped
        def drop!: () { (String) -> boolish } -> self?
      end
    RBS
    # drop! returns something else without a block: `?{` would be wrong.
    assert_equal <<~RBS, out
      class A
        # Yields pairs.
        def each: () { (Integer, Integer) -> void } -> self
                | () -> Enumerator[[Integer, Integer], self]
        def read: (untyped x) ?{ (untyped) -> untyped } -> untyped
        def drop!: () { (String) -> boolish } -> self?
      end
    RBS
    assert_includes applied, "A#each"
    assert_equal ["A#drop!: the block is optional (the source checks block_given?/the block): use `?{ ... }`"], left
  end

  def test_fix_enumerator_overload_keeps_params_and_aligns
    out, = fix(<<~RUBY, <<~RBS)
      class A
        def each_line(sep)
          return enum_for(:each_line, sep) unless block_given?
          yield "x"
          nil
        end
      end
    RUBY
      class A
        def each_line: (String sep) { (String) -> void } -> void
                     | (Integer sep) -> nil
      end
    RBS
    # The blockless overload returns no Enumerator: one is added after the
    # last overload, under its `|`, with the block overload's parameters.
    assert_includes out, "             | (String sep) -> Enumerator[String, untyped]\n"
  end

  def test_fix_module_function
    out, _, left = fix(<<~RUBY, <<~RBS)
      module A
        module_function
        def width = 80
        def height = 24
      end
    RUBY
      module A
        def self.width: () -> Integer
        def self.height: () -> Integer
        def height: () -> Integer
      end
    RBS
    assert_includes out, "def self?.width: () -> Integer"
    # An instance declaration already exists: self? would duplicate it.
    assert_includes out, "def self.height: () -> Integer"
    assert_finds(/A.height: module_function/, left)
  end

  def test_fix_bool_literals_and_string_constant
    out, _, left = fix(<<~RUBY, <<~RBS)
      module A
        def persisted? = false
        class B
          def check = yield(1)
        end
      end
    RUBY
      module A
        VERSION: "1.2.3"
        def persisted?: () -> false
        class B
          def check: () { (Integer) -> bool } -> void
                   | (Integer) { (Integer) -> bool } -> void
          def gone?: () -> true
        end
      end
    RBS
    assert_includes out, "VERSION: String\n"
    assert_includes out, "def persisted?: () -> bool\n"
    assert_equal 2, out.scan("-> boolish }").size
    # An RBS-only literal is a question for a human.
    assert_includes out, "def gone?: () -> true"
    assert_finds(/A::B#gone\?: returns the literal type true/, left)
  end

  def test_fix_privatized_mixin_methods
    out, applied, left = fix(<<~RUBY, <<~RBS, ns: %w[A Tools], lib: true)
      module Tools
        def run(x) = x
        def sh(*cmd) = cmd
      end
      module A
        include Tools
        private(*Tools.instance_methods(false))
      end
    RUBY
      module Tools
        type cmd = String | Array[String]
        def run: (String x) -> String
        def sh: (*cmd cmd) -> bool
              | (*cmd cmd) { (bool, untyped) -> void } -> Array[cmd]
      end
      module A
        include Tools
      end
    RBS
    assert_equal ["A"], applied
    # Tools's own alias is written so that it resolves from A too.
    assert_equal <<~RBS, out
      module Tools
        type cmd = String | Array[String]
        def run: (String x) -> String
        def sh: (*cmd cmd) -> bool
              | (*cmd cmd) { (bool, untyped) -> void } -> Array[cmd]
      end
      module A
        include Tools

        private

        def run: (String x) -> String
        def sh: (*::Tools::cmd cmd) -> bool
              | (*::Tools::cmd cmd) { (bool, untyped) -> void } -> Array[::Tools::cmd]
      end
    RBS
    refute(left.any? { _1.include?("makes Tools") }, left.inspect)

    # Declared in the module itself, publicly: made private in place.
    out, = fix(<<~RUBY, <<~RBS, ns: %w[A Tools], lib: true)
      module Tools
        def run(x) = x
      end
      module A
        include Tools
        private(*Tools.instance_methods(false))
      end
    RUBY
      module Tools
        def run: (String x) -> String
      end
      module A
        include Tools
        def run: (String x) -> String
      end
    RBS
    assert_includes out, "  include Tools\n  private def run: (String x) -> String\nend"
  end

  def test_fix_arity_default_becomes_optional
    out, _, left = fix(<<~RUBY, <<~RBS)
      class A
        def reload(force = false) = force
        def create_file(dest, *args, &block)
          data = args.first
          [dest, block || data.to_s]
        end
        def pick(a, b = 1) = a
      end
    RUBY
      class A
        def reload: (bool force) -> bool
        def create_file: (String dest, String data) -> untyped
                       | (String dest) { () -> String } -> untyped
        def pick: (String a, Integer b) -> String
                | (String a, String b) -> String
      end
    RBS
    assert_includes out, "def reload: (?bool force) -> bool"
    assert_includes out, "def create_file: (String dest, ?String data) -> untyped"
    # Both optional would make the overloads ambiguous: only the first.
    assert_includes out, "def pick: (String a, ?Integer b) -> String\n          | (String a, String b) -> String"
    assert_equal [], left
  end

  def test_fix_nil_return_only_when_explicit
    out, _, left = fix(<<~RUBY, <<~RBS)
      class A
        def first
          return nil if @items.empty?
          @items[0]
        end
        def pair
          return if @x
          @x
        end
        def label
          "x" if @on
        end
      end
    RUBY
      class A
        def first: () -> String
        def pair: () -> (String | Integer)
        def label: () -> String
      end
    RBS
    assert_includes out, "def first: () -> String?"
    assert_includes out, "def pair: () -> (String | Integer)?"
    assert_includes out, "def label: () -> String\n"
    assert_finds(/A#label: the source can end without a value/, left)
  end

  def test_fix_manifest
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.yaml"), "dependencies:\n  - name: logger\n  - monitor # sync\n")
      File.write(File.join(dir, "a.rbs"), "class A\n  def go: (URI::Generic u) -> Monitor\n  def at: () -> Date\nend\n")
      res = GemTypes::Lint.apply_fixes(GemTypes::Lint.layout(dir))
      assert_equal [], res[:failed]
      assert_equal "dependencies:\n  - name: logger\n  - name: monitor # sync\n  - name: uri\n  - name: date\n",
                   File.read(File.join(dir, "manifest.yaml"))
      refute(GemTypes::Lint.layout(dir).any? { |k, _| k == "manifest.yaml" })
    end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rbs"), "class A\n  def go: (URI::Generic u) -> Pathname\nend\n")
      GemTypes::Lint.apply_fixes(GemTypes::Lint.layout(dir))
      assert_equal "dependencies:\n  - name: uri\n  - name: pathname\n", File.read(File.join(dir, "manifest.yaml"))
    end
  end

  def test_fix_rolls_back_a_file_that_would_not_parse
    Dir.mktmpdir do |dir|
      sig = File.join(dir, "a.rbs")
      File.write(sig, "class A\n  def x: () -> Integer\nend\n")
      bad = GemTypes::Lint::Finding.new("A#x", "broken", [GemTypes::Lint::Edit.new(file: sig, range: 0...5, replacement: "klass")])
      res = GemTypes::Lint.apply_fixes([bad, ["A#y", "no fix"]])
      assert_equal "class A\n  def x: () -> Integer\nend\n", File.read(sig)
      assert_equal [], res[:applied]
      assert_match(/would not parse/, res[:failed].first.last)
    end
  end

  def test_findings_are_still_key_message_pairs
    f = GemTypes::Lint::Finding.new("A#x", "msg", [])
    key, msg = f
    assert_equal ["A#x", "msg"], [key, msg]
    assert_nil f.fix
    assert_equal [f], [f, ["A#x", "msg"]].uniq
  end
end
