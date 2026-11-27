# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
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

  def test_reopened_classes_need_declared_methods
    r = GemTypes::RbsReader.read(<<~RBS)
      module Diff::LCS
        def lcs: (untyped) -> untyped
      end
      class Array[unchecked out Elem]
        include Diff::LCS
      end
      class String
        def to_diff: () -> String
      end
    RBS
    config = GemTypes::Config.new(ns: ["Diff"])
    assert_equal ["String"], GemTypes::Verify.reopened(config, r)
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

  def test_raw_block_keys
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        class R
          def on(&blk) = (@cbs ||= []) << blk
          def before(&blk) = on(&blk)
          def each(&blk) = @cbs.each(&blk)
          def run(&blk) = blk.call(1)
          def both(&blk) = (@b = blk; yield)
        end
        class T
          def initialize(&blk) = (@blk = blk)
        end
        class P
          delegate :on, :run, to: :@r
          def trait(&blk) = T.new(&blk)
        end
      RUBY
      keys = GemTypes::DefIndex.new([dir]).raw_block_keys
      assert_equal %w[P#on P#trait R#before R#on T#initialize], keys.sort
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

  DETECT = File.expand_path("../libexec/detect_test_cmd.rb", __dir__)

  def detect(files, gemfile: "")
    Dir.mktmpdir do |dir|
      files.each do |f, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, f)))
        File.write(File.join(dir, f), body || "")
      end
      File.write(File.join(dir, "Gemfile.env"), gemfile)
      IO.popen([RbConfig.ruby, DETECT, dir, File.join(dir, "Gemfile.env")], &:read).strip
    end
  end

  def test_detect_test_cmd_lists_every_test_file
    cmd = detect({ "test/test_netrc.rb" => "", "test/sub/deep/a_test.rb" => "", "test/helper.rb" => "",
                   "test/it's_test.rb" => "" })
    assert_equal %q(for t in test/it\'s_test.rb test/sub/deep/a_test.rb test/test_netrc.rb; ) +
                 %q(do bundle exec ruby -Ilib -Itest "$t"; done), cmd
    assert_equal "bundle exec rake test", detect({ "test/a_test.rb" => "", "Rakefile" => "Rake::TestTask.new" })
  end

  def test_detect_test_cmd_spec_without_rspec
    assert_equal "bundle exec rake spec", detect({ "spec/a_spec.rb" => "", "Rakefile" => "task :spec do\nend\n" },
                                                 gemfile: %(gem "bacon"\n))
    assert_equal "bundle exec rspec", detect({ "spec/a_spec.rb" => "", "Rakefile" => "task :spec do\nend\n" },
                                             gemfile: %(gem "rspec", "~> 3"\n))
    assert_equal "bundle exec rspec", detect({ "spec/a_spec.rb" => "" })
  end

  def batch = GemTypes::Batch.new([], base: Dir.tmpdir)

  # The tracepoint hook records tagged tuples in returned Arrays (Hashdiff's
  # ["+", path, value] changes), only when every returned element has one.
  def test_observe_records_return_tuples
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "foo.rb"), <<~RUBY)
        module Foo
          def self.diff(a) = a ? [["+", "a.b", 1], ["~", "c", 1, "x"]] : []
          def self.pairs = [[1, 2]]
          def self.mixed(a) = a ? [["-", "a", nil]] : [1]
        end
      RUBY
      out = File.join(dir, "obs")
      FileUtils.mkdir_p(out)
      env = { "OBSERVE_NS" => "Foo", "OBSERVE_DIR" => out, "OBSERVE_LIB" => lib }
      hook = File.expand_path("../lib/gem_types/hooks/observe.rb", __dir__)
      assert system(env, "ruby", "-I#{lib}", "-r#{hook}", "-e", "require 'foo'; Foo.diff(true); Foo.diff(false); Foo.pairs; Foo.mixed(true); Foo.mixed(false)")
      data = JSON.parse(File.read(Dir[File.join(out, "*.json")].first))
      assert_equal ['["+", String, Integer]', '["~", String, Integer, String]'], data["Foo.diff"]["return_tuples"]
      assert_nil data["Foo.pairs"]["return_tuples"]
      assert_nil data["Foo.mixed"]["return_tuples"]
      assert_equal ['["+", Array | String, Hash | Integer]', '["~", String, Integer, nil]'],
                   GemTypes::Merger.collapse_tuples(['["+", String, Integer]', '["+", Array, Hash]', '["~", String, Integer, nil]'])
    end
  end

  # A branch left from an earlier (squash-merged) PR is restarted from the
  # ref; one that builds on the ref is reused.
  def test_worktree_restarts_stale_branches
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      git = ->(*a) { system("git", "-C", repo, *a, out: File::NULL, err: File::NULL) || raise("git #{a.join(" ")}") }
      FileUtils.mkdir_p(File.join(repo, "gems", "foo", "1.0"))
      File.write(File.join(repo, "gems", "foo", "1.0", "foo.rbs"), "")
      system("git", "init", "-q", "-b", "main", repo)
      git.("-c", "user.name=t", "-c", "user.email=t@t", "add", "-A")
      git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
      git.("branch", "update-foo")
      git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two")
      git.("branch", "add-bar", "main")
      main = IO.popen(["git", "-C", repo, "rev-parse", "main"], &:read).strip
      b = GemTypes::Batch.new([], base: File.join(dir, "base"), worktrees: repo, ref: "main")
      _, err = capture_io { b.send(:worktree, "foo") }
      assert_includes err, "restarting it from main"
      assert_equal main, IO.popen(["git", "-C", repo, "rev-parse", "update-foo"], &:read).strip
      _, err = capture_io { b.send(:worktree, "bar") }
      assert_empty err
      assert_equal "add-bar", IO.popen(["git", "-C", File.join(dir, "base", "wt", "bar"), "branch", "--show-current"], &:read).strip
    end
  end

  def test_next_fix_maps_required_files_to_gems
    b = batch
    fix = ->(text, gemfile = "", tried = [], root: nil) { b.send(:next_fix, text, {}, "x", tried, root: root, gemfile: gemfile) }
    assert_equal "test-unit", fix.("cannot load such file -- test/unit")[:gem]
    assert_equal "activesupport", fix.("cannot load such file -- active_support")[:gem]
    assert_equal "minitest-reporters", fix.("cannot load such file -- minitest/reporters", %(gem "minitest", "~> 5.0"\n))[:gem]
    # a gem already in the Gemfile is not rewritten
    assert_nil fix.("cannot load such file -- minitest/pride", %(gem "minitest", "~> 5.0"\n), %w[gem-minitest-pride gem-minitest_pride])
    assert_equal "rspec-its", fix.("cannot load such file -- rspec/its")[:gem]
    assert_equal "foo-bar", fix.("cannot load such file -- foo/bar")[:gem]
    assert_equal "foo_bar", fix.("cannot load such file -- foo/bar", "", ["gem-foo-bar"])[:gem]
    assert_equal "foo", fix.("cannot load such file -- foo/bar", "", %w[gem-foo-bar gem-foo_bar])[:gem]
    assert_nil fix.("cannot load such file -- spec_helper")
    assert_equal "rake", fix.("can't find executable rake for gem rake. rake is not currently included in the bundle")[:gem]
    # the gem's own C extension, not built yet
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "ext", "unf_ext"))
      File.write(File.join(root, "ext", "unf_ext", "extconf.rb"), "")
      assert_equal "bundle exec rake compile", fix.("cannot load such file -- 3.3/unf_ext.so", root: root)[:pre]
      assert_equal "gem-other", fix.("cannot load such file -- other", root: root)[:name]
      FileUtils.mkdir_p(File.join(root, "ext", "nio4r"))
      File.write(File.join(root, "ext", "nio4r", "extconf.rb"), %(create_makefile("nio4r_ext")\n))
      assert_equal "compile", fix.("cannot load such file -- nio4r_ext", root: root)[:name]
    end
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "test", "support"))
      File.write(File.join(dir, "test", "support", "x.rb"), "")
      assert_nil fix.("cannot load such file -- support/x", root: dir)
    end
    # the minitest 5 pin may rewrite the minitest line
    assert_equal({ name: "minitest5", gem: "minitest", req: "~> 5.0" },
                 fix.("undefined method `must_equal' for 1", %(gem "minitest"\n)))
  end

  def test_fix_kept_only_when_failures_do_not_increase
    b = batch
    better = ->(c1, c2, changed = false) { b.send(:better?, { total: c1[0], failed: c1[1] }, { total: c2[0], failed: c2[1] }, changed: changed) }
    assert better.([0, 1], [10, 2])
    assert better.([0, 1], [0, 1], true)
    refute better.([0, 1], [0, 1])
    assert better.([10, 2], [12, 2])
    assert better.([10, 2], [10, 1])
    refute better.([10, 2], [12, 3])
    refute better.([10, 2], [10, 3], true)
    assert better.([10, 2], [10, 2], true)
  end

  def test_namespace_script_finds_new_modules_under_existing_ones
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(File.join(lib, "net", "http"))
      File.write(File.join(lib, "net", "http", "persistent.rb"), <<~RUBY)
        require "net/http"
        class Net::HTTP::Persistent
          class Error < StandardError; end
        end
        module Comparable; def zz_gem_types_test; end; end
        module TopLevelThing; end
      RUBY
      script = batch.send(:namespace_script, "net/http/persistent", lib)
      out = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", script], &:read)
      assert_equal %w[Net::HTTP::Persistent TopLevelThing], out.lines(chomp: true).sort
    end
  end

  def test_namespace_script_skips_namespaces_shared_with_dependencies
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      dep = File.join(dir, "dep")
      FileUtils.mkdir_p([lib, dep])
      File.write(File.join(dep, "shared_dep.rb"), "module SharedNs; class Request; end; end\n")
      File.write(File.join(lib, "shared_mine.rb"), <<~RUBY)
        module SharedNs; end
        require "shared_dep"
        module SharedNs
          class Mine; class Inner; end; end
        end
      RUBY
      script = batch.send(:namespace_script, "shared_mine", lib)
      out = IO.popen([RbConfig.ruby, "-I#{lib}", "-I#{dep}", "-e", script], &:read)
      assert_equal %w[SharedNs::Mine], out.lines(chomp: true)
    end
  end

  PICK = File.expand_path("../libexec/pick_gems.rb", __dir__)

  def test_pick_open_pr_title_matching
    load PICK unless defined?(names_gem?)
    assert names_gem?("Add rack", "rack")
    assert names_gem?("rack: fix Rack::Request", "rack")
    refute names_gem?("Add rack-test", "rack")
    refute names_gem?("Add rack_test", "rack")
    assert names_gem?("Add rack-test and rack", "rack")
    assert names_gem?("Update RSPEC-core", "rspec-core")
  end

  def def_index(src)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), src)
      return GemTypes::DefIndex.new([dir])
    end
  end

  def test_def_index_constant_receivers_are_singleton
    d = def_index(<<~RUBY)
      module Net
        class POP3
          def POP3.start; end
          def self.other; end
        end
      end
      module Foo
        class << Foo
          def on_foo; end
        end
      end
    RUBY
    keys = d.map { _1[:key] }
    assert_equal %w[Net::POP3.start Net::POP3.other Foo.on_foo], keys
  end

  def test_def_index_trailing_nodoc
    d = def_index(<<~RUBY)
      module Foo
        class A # :nodoc:
          def a1; end

          def a2; end
        end
        class B
          def b1; end # :nodoc:
          def b2; end
          def b3 # :nodoc:
          end
          # :nodoc:
          def b4; end
        end
      end
    RUBY
    assert_equal %w[Foo::A#a1 Foo::A#a2 Foo::B#b1 Foo::B#b3 Foo::B#b4], d.hidden.keys.sort
  end

  def test_def_index_module_function_and_visibility_sections
    d = def_index(<<~RUBY)
      module M
        module_function
        def mf; end
        private
        def helper; end
        public
        def pub; end
      end
      module N
        def x; end
        module_function :x
      end
      class C
        protected
        if true
          def in_if; end
        end
        def after_if; end
        public
        def open; end
      end
    RUBY
    keys = d.map { _1[:key] }
    assert_equal %w[M#mf M.mf M#helper M#pub N#x N.x C#in_if C#after_if C#open], keys
    assert_equal({ "M#mf" => "module_function", "M#helper" => "private", "N#x" => "module_function",
                   "C#in_if" => "protected", "C#after_if" => "protected" }, d.hidden)
  end

  def test_def_index_wrapped_definitions
    d = def_index(<<~RUBY)
      class W
        private attr_reader :pa
        private memoize def pm; end
        module_function def nope; end
        private_class_method def self.pc; end
      end
    RUBY
    assert_equal %w[W#pm W#nope W.nope W.pc], d.map { _1[:key] }
    assert_equal %w[W#pa], d.attrs.keys
    assert_equal({ "W#pa" => "private", "W#pm" => "private", "W#nope" => "module_function", "W.pc" => "private" }, d.hidden)
  end

  def test_def_index_class_new_and_struct_block_argument
    d = def_index(<<~RUBY)
      module Foo
        K = Class.new do
          def k1; end
        end
        EXT = proc { }
        P = Struct.new(:a, &EXT)
      end
    RUBY
    assert_includes d.map { _1[:key] }, "Foo::K#k1"
    assert_equal %w[Foo::P#a], d.attrs.keys
  end

  def test_def_index_tail_expressions
    d = def_index(<<~RUBY).to_h { [_1[:key], _1] }
      class T
        def pair(x) = (return x, x.to_s)
        def safe(s)
          Integer(s)
        rescue ArgumentError
          fallback
        end
        def memo = @m ||= compute
        def andor(a) = a && a.to_s
        def lit = :sym
        def pm(v)
          case v
          in Integer then one
          end
        end
      end
    RUBY
    slice = ->(k) { d[k][:lasts].map { |(_, l, c, _, ec)| [l, c, ec] } }
    assert_empty d["T#pair"][:lasts]
    assert_equal ["Array[untyped]"], d["T#pair"][:fixed_returns]
    assert_equal [[4, 4, 14], [6, 4, 12]], slice.("T#safe")
    assert_equal [[8, 20, 27]], slice.("T#memo")
    assert_equal [[9, 22, 28]], slice.("T#andor")
    assert_equal [[9, 17, 18]], d["T#andor"][:falsy_lasts].map { |(_, l, c, _, ec)| [l, c, ec] }
    assert_equal ["Symbol"], d["T#lit"][:fixed_returns]
    assert_equal [[13, 20, 23]], slice.("T#pm")
    refute d["T#pm"][:implicit_nil]
  end

  # --- draft, RBS reading and comparison fixes ---

  Defs = Struct.new(:attrs, :hidden)

  def tp_evidence(**kw)
    GemTypes::Evidence.new(source: "tracepoint", params: [], block: ["no"], returns: [], raises: [], calls: 1, **kw)
  end

  def assert_rbs_parses(text)
    RBS::Parser.parse_signature(text)
  rescue RBS::ParsingError => e
    flunk "does not parse: #{e.message.lines.first}\n#{text}"
  end

  def test_to_rbs_orders_params_and_keeps_first_rest
    e = tp_evidence(params: [{ kind: "key", name: "verbose", types: ["bool"] }, { kind: "rest", name: "args", types: [] },
                             { kind: "rest", name: "more", types: [] }, { kind: "req", name: "a", types: ["String"] },
                             { kind: "keyrest", name: "o", types: [] }, { kind: "keyrest", name: "p", types: [] }],
                    returns: ["Integer"])
    assert_equal "(*untyped args, String a, ?verbose: bool, **untyped o) -> Integer", e.to_rbs
    RBS::Parser.parse_method_type(e.to_rbs, require_eof: true)
  end

  def test_draft_quotes_method_names_rbs_cannot_parse
    m = GemTypes::Merger.new(evidence: { "tracepoint" => { "K#valid?_with_rescue" => tp_evidence(returns: ["bool"]),
                                                           "K.a?b" => tp_evidence(returns: ["bool"]) } })
    d = m.draft
    assert_includes d, "def `valid?_with_rescue`: () -> bool"
    assert_includes d, "def self.`a?b`: () -> bool"
    assert_rbs_parses d
  end

  def test_draft_writes_aliases
    existing = GemTypes::RbsReader.read(<<~RBS).methods
      class K
        def run: () -> Integer
        alias go run
        alias self.make self.build
      end
    RBS
    d = GemTypes::Merger.new(evidence: { "typeprof" => { "K.build" => GemTypes::Evidence.new(source: "typeprof", sigs: ["() -> K"]) } },
                             existing: existing).draft
    assert_includes d, "  alias go run"
    assert_includes d, "  alias self.make self.build"
    refute_includes d, "(*untyped) -> untyped"
    assert_rbs_parses d
    # The aliased method is not declared: its signature is used.
    m = GemTypes::Merger.new(evidence: { "typeprof" => {
      "K#go" => GemTypes::Evidence.new(source: "typeprof", sigs: ["(alias of run)"]),
      "K#run" => GemTypes::Evidence.new(source: "typeprof", sigs: ["() -> Integer"])
    } }, defs: Defs.new({}, { "K#run" => "private" }))
    assert_equal ["() -> Integer", "typeprof"], m.pick("K#go")
    assert_includes m.draft, "def go: () -> Integer"
  end

  def test_draft_attr_only_for_the_matching_half
    ev = { "tracepoint" => {
      "K#x" => tp_evidence(returns: ["String"]),
      "K#x=" => tp_evidence(params: [{ kind: "req", name: "v", types: ["String"] }], returns: ["String"]),
      "K#y" => tp_evidence(returns: ["Integer"]),
      "K#y=" => tp_evidence(params: [{ kind: "req", name: "v", types: ["Integer"] }], returns: ["Integer"])
    } }
    d = GemTypes::Merger.new(evidence: ev, defs: Defs.new({ "K#x" => { kind: "reader" }, "K#y" => { kind: "writer" } }, {})).draft
    assert_equal 1, d.scan("attr_reader x: String").size
    assert_includes d, "def x=: (String v) -> String"
    assert_equal 1, d.scan("attr_writer y: Integer").size
    assert_includes d, "def y: () -> Integer"
  end

  def test_draft_private_writer_makes_a_reader
    ev = { "tracepoint" => { "K#x" => tp_evidence(returns: ["String"]) } }
    attrs = { "K#x" => { kind: "accessor" } }
    d = GemTypes::Merger.new(evidence: ev, defs: Defs.new(attrs, { "K#x=" => "private" })).draft
    assert_includes d, "attr_reader x: String"
    refute_includes d, "attr_accessor x"
    d = GemTypes::Merger.new(evidence: ev, defs: Defs.new(attrs, { "K#x=" => "private" }),
                             existing: { "K#x=" => ["(String) -> String"] }).draft
    assert_includes d, "attr_accessor x: String"
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "m.rb"), "module M\n  class K\n    attr_accessor :x\n    private :x=\n  end\nend\n")
      defs = GemTypes::DefIndex.new([dir])
      d = GemTypes::Merger.new(evidence: { "tracepoint" => { "M::K#x" => tp_evidence(returns: ["String"]) } }, defs: defs).draft
      assert_includes d, "attr_reader x: String"
    end
  end

  def test_attr_type_parses_the_method_type
    m = GemTypes::Merger.new(evidence: {})
    assert_equal "String", m.send(:attr_type, "() { (Integer) -> void } -> String", nil)
    assert_equal "untyped", m.send(:attr_type, "() -> void", nil)
    assert_equal "untyped", m.send(:attr_type, "() -> self", nil)
    assert_equal "Integer", m.send(:attr_type, "() -> untyped", "(Integer v) -> Integer")
    assert_equal "Integer", m.send(:attr_type, nil, "(Integer v) { () -> void } -> void")
    assert_equal "untyped", m.send(:attr_type, "[T] () -> T", "(*untyped) -> void")
    assert_equal "(String | Symbol)?", m.send(:attr_type, "() -> (String | Symbol)?", nil)
  end

  def test_rbs_reader_keeps_superclass_type_arguments
    r = GemTypes::RbsReader.read("class Foo < Hash[String, Integer]\nend\nclass Bar\nend\n")
    assert_equal({ kind: "class", super: "Hash", super_args: %w[String Integer] }, r.classes["Foo"])
    d = GemTypes::Merger.new(evidence: { "tracepoint" => { "Foo#x" => tp_evidence(returns: ["String"]) } }, classes: r.classes).draft
    assert_includes d, "class Foo < Hash[String, Integer]"
  end

  def test_rbs_reader_superclass_from_a_later_declaration
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rbs"), "class A\n  def x: () -> void\nend\n")
      File.write(File.join(dir, "b.rbs"), "class A < B\nend\nclass A < C\nend\n")
      r = GemTypes::RbsReader.read_files([File.join(dir, "a.rbs"), File.join(dir, "b.rbs")])
      assert_equal "B", r.classes["A"][:super]
    end
  end

  def test_rbs_reader_visibility_sections
    rbs = <<~RBS
      class K
        private
        def self.build: () -> K
        def helper: () -> void
        def self?.both: () -> void
        attr_reader secret: String
        attr_accessor self.conf: Integer
        public
        attr_writer open: String
      end
    RBS
    r = GemTypes::RbsReader.read(rbs)
    assert r.methods.key?("K.build")
    refute r.methods.key?("K#helper")
    assert r.methods.key?("K.both")
    refute r.methods.key?("K#both")
    refute r.methods.key?("K#secret")
    assert r.methods.key?("K.conf")
    assert r.methods.key?("K.conf=")
    assert r.methods.key?("K#open=")
    all = GemTypes::RbsReader.read(rbs, include_private: true)
    assert all.methods.key?("K#secret")
    assert all.methods.key?("K#both")
  end

  def test_rbs_reader_keeps_overloading_dots
    existing = GemTypes::RbsReader.read("class String\n  def blank?: () -> bool | ...\nend\n").methods
    assert_equal ["() -> bool", "..."], existing["String#blank?"]
    d = GemTypes::Merger.new(evidence: {}, existing: existing).draft
    assert_includes d, "def blank?: () -> bool | ..."
    assert_rbs_parses d
    assert_equal "() -> bool || ...", GemTypes.canonical("() -> bool | ...")
  end

  def test_rbs_reader_skips_bad_lines_and_scrubs_utf8
    text = "class K\n  def a: () -> String\n  def b: (*untyped *x) -> void\n  def c: () -> Integer\nend\n: junk\n"
    r = nil
    _, err = capture_io { r = GemTypes::RbsReader.read(text, "t.rbs") }
    assert_equal %w[K#a K#c], r.methods.keys.sort
    assert_match(/line 3 skipped/, err)
    assert_match(/line 6 skipped/, err)
    r = nil
    capture_io { r = GemTypes::RbsReader.read("class K\n  # caf\xFF\n  def a: () -> String\nend\n".b) }
    assert_equal ["K#a"], r.methods.keys
  end

  def test_draft_merges_existing_classes_and_reads_a_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "_test"))
      File.write(File.join(dir, "m.rbs"), "module M\n  def self.x: () -> void\nend\n")
      File.write(File.join(dir, "_test", "t.rbs"), "class T\nend\n")
      files = GemTypes::RbsReader.sig_files(dir)
      assert_equal [File.join(dir, "m.rbs")], files
      r = GemTypes::RbsReader.read_files(files)
      classes = GemTypes::Merger.with_existing_classes({ "M" => { kind: "class", super: nil } }, r.classes)
      d = GemTypes::Merger.new(evidence: {}, classes: classes, existing: r.methods).draft
      assert_includes d, "module M"
    end
  end

  def test_canonical_parses_overloads
    assert_equal "(Integer) -> String || [T] (T) -> T", GemTypes.canonical("(Integer) -> String | [T] (T) -> T")
    assert_equal "() -> Integer | String | Symbol | nil", GemTypes.canonical("() -> (String | (Integer | Symbol)?)")
    assert_nil GemTypes.canonical("() -> String garbage")
    m = GemTypes::Merger.new(evidence: {})
    assert_equal "def initialize: (String a) -> void | ...", "def initialize: #{m.send(:void_return, '(String a) -> K | ...')}"
  end

  def test_equivalent_signatures_do_not_disagree
    assert_equal GemTypes.projection("(String | Symbol) -> Foo"), GemTypes.projection("(Symbol) -> Foo | (String) -> Foo")
    assert_equal GemTypes.projection("(String?) -> Foo"), GemTypes.projection("(nil | String) -> Foo")
    ev = lambda do |tp, lumi|
      { "tracepoint" => { "K#m" => GemTypes::Evidence.new(source: "tracepoint", sigs: [tp], calls: 1, returns: ["x"], raises: []) },
        "lumitrace" => { "K#m" => GemTypes::Evidence.new(source: "lumitrace", sigs: [lumi], calls: 1) } }
    end
    refute_includes GemTypes::Merger.new(evidence: ev.("(Hash[Symbol, String] h, *Symbol a) -> Array[Integer]", "(Hash h, *Array a) -> Array")).flags("K#m"),
                    "runtime sources disagree"
    assert_includes GemTypes::Merger.new(evidence: ev.("(Hash[Symbol, String] h) -> Array[Integer]", "(Hash h) -> String")).flags("K#m"),
                    "runtime sources disagree"
  end

  def test_comparison_of_self_and_type_variables
    m = GemTypes::Merger.new(evidence: {})
    assert_equal "() -> singleton(K)", m.send(:comparable, "() -> self", "K", ".")
    assert_equal "() -> K", m.send(:comparable, "() -> self", "K", "#")
    ev = { "tracepoint" => { "K.make" => GemTypes::Evidence.new(source: "tracepoint", sigs: ["() -> self"], calls: 1, returns: ["x"], raises: []),
                             "K#wrap" => GemTypes::Evidence.new(source: "tracepoint", sigs: ["[T] () { () -> T } -> T"], calls: 1, returns: ["x"], raises: []) },
           "rbs_trace" => { "K.make" => GemTypes::Evidence.new(source: "rbs_trace", sigs: ["() -> singleton(K)"], calls: 1),
                            "K#wrap" => GemTypes::Evidence.new(source: "rbs_trace", sigs: ["() -> Integer"], calls: 1) } }
    m = GemTypes::Merger.new(evidence: ev)
    refute_includes m.flags("K.make"), "runtime sources disagree"
    refute_includes m.flags("K#wrap"), "runtime sources disagree"
  end

  def test_union_parenthesizes_before_question_mark
    assert_equal "(:foo)?", GemTypes.union([":foo", "nil"])
    assert_equal "(^() -> void)?", GemTypes.union(["^() -> void", "nil"])
    assert_equal "String?", GemTypes.union(["String?", "nil"])
    assert_equal "Array[String?]?", GemTypes.union(["Array[String?]", "nil"])
    %w[:foo ^()\ ->\ void String? Array[String?]].each do |t|
      RBS::Parser.parse_type(GemTypes.union([t, "nil"]), require_eof: true)
    end
  end

  def test_update_and_pr_text_expand_attrs
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "old"), File.join(dir, "new")])
      File.write(File.join(dir, "old", "m.rb"), "module M\n  class K\n    attr_accessor :size\n    attr_accessor :pw\n    private :pw=\n  end\nend\n")
      File.write(File.join(dir, "new", "m.rb"), "module M\n  class K\n    attr_reader :size\n    attr_accessor :pw\n    private :pw=\n  end\nend\n")
      old_defs = GemTypes::DefIndex.new([File.join(dir, "old")])
      assert_equal %w[M::K#pw M::K#size M::K#size=], GemTypes::Update.attr_keys(old_defs).sort
      changes = GemTypes::Update.compare_defs(old_defs, GemTypes::DefIndex.new([File.join(dir, "new")]))
      assert_equal ["M::K#size="], changes[:removed]
      assert_empty changes[:added]
    end
  end

  def test_pr_text_reports_missing_writer_and_skips_test_rbs
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "repo", "lib"), File.join(dir, "sig", "1.0", "_test"), File.join(dir, "out")])
      File.write(File.join(dir, "repo", "lib", "m.rb"), "module M\n  class K\n    attr_accessor :size\n  end\nend\n")
      File.write(File.join(dir, "sig", "1.0", "m.rbs"), "module M\n  class K\n    attr_reader size: Integer\n  private\n    attr_reader cache: String\n  end\nend\n")
      File.write(File.join(dir, "sig", "1.0", "_test", "t.rbs"), "module M\n  class TestOnly\n    def x: () -> void\n  end\nend\n")
      cfg = GemTypes::Config.new(repo: File.join(dir, "repo"), lib_dirs: ["lib"], test_dirs: [], ns: ["M"], requires: [],
                                 env: {}, out: File.join(dir, "out"))
      text = GemTypes::PrText.build(cfg, dir, File.join(dir, "sig", "1.0"))
      assert_includes text, "`M::K#size=`"
      refute_includes text, "TestOnly"
      refute_includes text, "cache"
    end
  end

  def test_counts_errors_outside_of_examples_as_failures
    c = GemTypes::Verify.test_counts("0 examples, 0 failures, 1 error occurred outside of examples\n")
    assert_equal({ total: 0, failed: 1, unit: "examples", outside: 1 }, c)
    c = GemTypes::Verify.test_counts("10 examples, 1 failure\n5 runs, 9 assertions, 1 failures, 2 errors, 0 skips\n")
    assert_equal 15, c[:total]
    assert_equal 4, c[:failed]
  end

  def test_incomplete_checked_run
    plain = { total: 42, failed: 0, unit: "examples" }
    v = GemTypes::Verify
    assert_empty v.incomplete_reasons(plain, plain, 86)
    crashed = { total: 0, failed: 1, unit: "examples" }
    r = v.incomplete_reasons(plain, crashed, 0, checked_ok: false)
    assert_equal 5, r.size
    assert_includes r.join, "counted no tests"
    refute_empty v.incomplete_reasons(plain, { total: 40, failed: 0, unit: "examples" }, 80)
    refute_empty v.incomplete_reasons(plain, plain, 0)
    refute_empty v.incomplete_reasons(plain, { total: 42, failed: 2, unit: "examples" }, 86)
    # Failing tests in both runs are not a broken checked run.
    failing = { total: 42, failed: 2, unit: "examples" }
    assert_empty v.incomplete_reasons(failing, failing, 86, plain_ok: false, checked_ok: false)
  end

  def test_satisfies_singleton_members
    anc = { "Foo::Sub" => %w[Foo::Sub Foo::Base Object BasicObject], "Foo::Mod" => %w[Foo::Mod] }
    v = GemTypes::Verify
    assert v.satisfies?("singleton(Foo::Base)", "singleton(Base)", "Foo::X", anc)
    assert v.satisfies?("singleton(Foo::Sub)", "singleton(Base)", "Foo::X", anc)
    refute v.satisfies?("singleton(String)", "singleton(Base)", "Foo::X", anc)
    refute v.satisfies?("Foo::Base", "singleton(Base)", "Foo::X", anc)
    assert v.satisfies?("singleton(Foo::Sub)", "Class", "Foo", anc)
    assert v.satisfies?("singleton(Foo::Sub)", "Module", "Foo", anc)
    assert v.satisfies?("singleton(Foo::Mod)", "Module", "Foo", anc)
    refute v.satisfies?("singleton(Foo::Mod)", "Class", "Foo", anc)
    refute v.satisfies?("singleton(Foo::Sub)", "String", "Foo", anc)
  end

  def test_sig_files_skip_underscore_dirs
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "_test"))
      FileUtils.mkdir_p(File.join(dir, "sub"))
      %w[a.rbs sub/b.rbs _test/test.rbs].each { |f| File.write(File.join(dir, f), "") }
      assert_equal [File.join(dir, "a.rbs"), File.join(dir, "sub/b.rbs")], GemTypes::Verify.sig_files(dir)
      assert_equal [File.join(dir, "_test/test.rbs")], GemTypes::Verify.sig_files(File.join(dir, "_test/test.rbs"))
    end
  end

  def test_parse_sigs_is_strict
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ok.rbs"), "class A\nend\n")
      assert_equal 1, GemTypes::Verify.parse_sigs(dir).size
      File.write(File.join(dir, "bad.rbs"), "class A\n  def x: () -> String |\nend\n")
      err = assert_raises(GemTypes::Verify::SigError) { GemTypes::Verify.parse_sigs(dir) }
      assert_includes err.message, "bad.rbs"
      FileUtils.rm_f(Dir[File.join(dir, "*")])
      assert_raises(GemTypes::Verify::SigError) { GemTypes::Verify.parse_sigs(dir) }
    end
  end

  def test_sig_structure_resolves_superclasses_in_context
    _, _, decls = RBS::Parser.parse_signature(<<~RBS)
      module Slop
        class Error < StandardError
        end
        class MissingArgument < Error
          alias flag name
        end
        class Other < ::Error
        end
        module Deep
          class K < Thing
          end
        end
      end
    RBS
    st = GemTypes::Verify.sig_structure([["x.rbs", decls]])
    v = GemTypes::Verify
    sup = ->(n) { v.super_candidates(st[:classes][n][:supers].first, st[:classes]) }
    assert_equal ["Slop::Error"], sup.("Slop::MissingArgument")
    assert_equal ["Slop::StandardError", "StandardError"], sup.("Slop::Error")
    assert_equal ["Error"], sup.("Slop::Other")
    assert_equal ["Slop::Deep::Thing", "Slop::Thing", "Thing"], sup.("Slop::Deep::K")
    assert_equal [["Slop::MissingArgument", "#", "flag", "name"]], st[:aliases]
    assert_equal "module", st[:classes]["Slop::Deep"][:kind]
  end

  def test_options_hash_lint
    v = GemTypes::Verify
    params = [{ kind: "req", name: "name" }, { kind: "opt", name: "opts", hash_default: true }]
    msg = v.options_hash_lint(params, ["(String name, ?verbose: bool) -> void"])
    assert_includes msg, "(untyped name, ?Hash[Symbol, untyped] opts)"
    assert_nil v.options_hash_lint(params, ["(String name, ?verbose: bool) -> void", "(String, Hash[Symbol, untyped]) -> void"])
    assert_nil v.options_hash_lint(params, ["(String name) -> void"]) # no keywords: another problem
    only = [{ kind: "opt", name: "opts", hash_default: true }]
    refute_nil v.options_hash_lint(only, ["(?verbose: bool) -> void"])
    assert_nil v.options_hash_lint(only + [{ kind: "key", name: "k" }], ["(?verbose: bool) -> void"])
  end

  COVERAGE = File.expand_path("../libexec/coverage_report.rb", __dir__)

  def test_coverage_report_uses_method_owner
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rbs"), <<~RBS)
        module M
          def to_s: () -> String
          def label: () -> String
          def self?.util: () -> String
        end
        class Base
          def greet: () -> String
          def self.make: () -> Base
          def initialize: () -> void
        end
        class Child < Base
          def greet: () -> String
        end
      RBS
      File.write(File.join(dir, "calls"), [
        "M\tself\tto_s\tinst:Module",        # Module#to_s on M: not M#to_s
        "Child\tinst\tlabel\tinst:M",        # included
        "M\tself\tutil\tself:M",             # module_function: both copies
        "Child\tinst\tgreet\tinst:Child",    # override: not Base#greet
        "Child\tself\tmake\tself:Base",      # inherited singleton
        "Base\tself\tnew\tself:Class",
        "ANC\tChild\tChild,M,Base,Object"
      ].join("\n") + "\n")
      out = IO.popen([RbConfig.ruby, COVERAGE, File.join(dir, "a.rbs"), File.join(dir, "calls")], err: File::NULL, &:read)
      assert_equal %w[M#to_s Base#greet], out.split("\n")
    end
  end
end
