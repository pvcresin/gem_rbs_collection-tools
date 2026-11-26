# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"
require "prism"

module GemTypes
  # Settings shared by all sources.
  #   repo:      checkout of the gem (upstream repo or unpacked package)
  #   lib_dirs:  library directories, relative to repo (default ["lib"])
  #   test_dirs: test directories, relative to repo, for static tools
  #   ns:        namespaces to keep, e.g. ["Netrc"] (nested ones included)
  #   requires:  what to require to load the gem (rbs prototype runtime)
  #   test_cmd:  shell command that runs the test suite, run in repo
  #   env:       extra environment for the test command (BUNDLE_GEMFILE, GEM_HOME...)
  #   out:       directory for raw outputs
  Config = Struct.new(:repo, :lib_dirs, :test_dirs, :ns, :requires, :test_cmd, :env, :out, keyword_init: true) do
    def lib_paths = lib_dirs.map { |d| File.expand_path(d, repo) }
    def test_paths = test_dirs.map { |d| File.expand_path(d, repo) }.select { |d| File.exist?(d) }

    def in_ns?(key)
      owner, = GemTypes.split_key(key)
      ns.empty? || ns.any? { |n| owner == n || owner.start_with?("#{n}::") }
    end
  end

  # Each source has #run (produce raw output) and #read (raw output ->
  # { key => Evidence }). They can be run separately: `collect` runs, `draft`
  # reads whatever raw output exists.
  module Sources
    RUNTIME = %w[tracepoint rbs_trace lumitrace].freeze
    STATIC = %w[typeprof tyda yard rigor prototype].freeze
    ALL = (RUNTIME + STATIC).freeze

    def self.for(name, config) = const_get(name.split("_").map(&:capitalize).join).new(config)

    class Base
      attr_reader :config
      # Extra environment for test runs (collect gives concurrent runs their
      # own TMPDIR).
      attr_accessor :extra_env
      # Seconds a command may run (collect limits the static tools: TypeProf
      # can run for most of an hour on rake and write nothing).
      attr_accessor :time_limit
      attr_reader :timed_out

      def initialize(config) = @config = config
      def name = self.class.name.split("::").last.gsub(/(?<!^)([A-Z])/, '_\1').downcase
      def dir = File.join(config.out, name)

      # Runs a command. By default outside this tool's bundle (the gem's own
      # environment); `tool: true` keeps this tool's bundle (for tools in our
      # Gemfile). Builds the environment explicitly so sources can run in
      # threads (Bundler.with_unbundled_env changes the global ENV).
      def sh(env, cmd, chdir:, log:, tool: false)
        FileUtils.mkdir_p(File.dirname(log))
        base = tool || !defined?(Bundler) ? ENV.to_h : Bundler.unbundled_env
        # Tools such as YARD read files in the locale encoding.
        base = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }.merge(base) unless base["LANG"].to_s.include?("UTF-8")
        full = base.merge(env).compact
        cmd = "timeout -k 10 #{time_limit.to_i} bash -c #{cmd.shellescape}" if time_limit
        ok = system(full, "bash", "-c", cmd, chdir: chdir, out: log, err: %i[child out], unsetenv_others: true)
        @timed_out = time_limit && $?.exitstatus == 124
        if @timed_out
          warn "#{name}: stopped after #{time_limit.to_i}s (GEM_TYPES_STATIC_TIMEOUT)"
        elsif !ok
          warn "#{name}: command failed (see #{log})"
        end
        ok
      end

      def tool_bin(gem, exe = gem) = "#{RbConfig.ruby.shellescape} #{Gem.bin_path(gem, exe).shellescape}"

      # Runs the test command with an extra -r hook.
      def run_tests(hook, env)
        raise "#{name}: --test-cmd is required" unless config.test_cmd

        # The caller's RUBYOPT without this tool's bundle (-rbundler/setup).
        outer = defined?(Bundler) ? Bundler.unbundled_env["RUBYOPT"] : ENV.fetch("RUBYOPT", nil)
        rubyopt = ["-r#{hook}", config.env["RUBYOPT"], outer].compact.reject(&:empty?).join(" ")
        # `bundle exec rspec` normally loads rspec inside the bundle process,
        # where the hooks have skipped themselves; make it exec instead.
        full = config.env.merge(extra_env || {}).merge(env).merge("RUBYOPT" => rubyopt, "BUNDLE_DISABLE_EXEC_LOAD" => "true")
        ok = sh(full, GemTypes.timed(config.test_cmd), chdir: config.repo, log: File.join(config.out, "#{name}.log"))
        warn "#{name}: no output recorded (did the test command run Ruby?)" if Dir[File.join(dir, "**", "*")].none? { |f| File.file?(f) }
        ok
      end

      def keep(hash) = hash.select { |k, _| config.in_ns?(k) }
    end

    # Our own TracePoint hook: per call shape, normal vs raising calls.
    class Tracepoint < Base
      def run
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        run_tests(File.join(HOOKS, "observe.rb"),
                  "OBSERVE_DIR" => dir, "OBSERVE_LIB" => config.lib_paths.join(":"), "OBSERVE_NS" => config.ns.flat_map { |n| [n, "#{n}::*"] }.join(","))
      end

      def read
        out = {}
        Dir[File.join(dir, "*.json")].each do |f|
          JSON.parse(File.read(f, encoding: "UTF-8")).each do |key, d|
            next if key == "__ancestors__"

            e = out[key] ||= Evidence.new(source: name, params: [], block: [], returns: [], raises: [], calls: 0,
                                          self_returns: [0, 0], block_passthrough: [0, 0], block_args: [],
                                          block_returns: [], block_self: [], returns_without_block: [])
            e.calls += d["calls"]
            e.block |= d["block"]
            e.returns |= d["returns"]
            e.raises |= d["raises"].map { |r| r.delete_prefix("raise ") }
            %w[self_returns block_passthrough].each do |f|
              e[f.to_sym] = e[f.to_sym].zip(d[f] || [0, 0]).map(&:sum)
            end
            (d["block_args"] || []).each_with_index { |ts, i| e.block_args[i] = (e.block_args[i] || []) | ts }
            e.block_returns |= d["block_returns"] || []
            e.block_self |= d["block_self"] || []
            e.returns_without_block |= d["returns_without_block"] || []
            d["kinds"].each do |label, (kind, pname)|
              # Anonymous `*` / `**` (from `...` too) have an empty name.
              p = e.params.find { |x| x[:name] == pname && (!pname.empty? || x[:kind] == kind) } ||
                  (e.params << { kind: kind, name: pname, types: [] }).last
              p[:types] |= d["params"][label] || []
            end
          end
        end
        out.each_value { |e| e.params = nil if e.params.empty? && e.returns.empty? }
        keep(out)
      end

      # Class name => ancestor names for every value class the hook saw.
      def ancestors
        Dir[File.join(dir, "*.json")].each_with_object({}) do |f, h|
          h.merge!(JSON.parse(File.read(f, encoding: "UTF-8"))["__ancestors__"] || {})
        end
      end

      # The human-readable per-shape files, for the report.
      def shapes
        Dir[File.join(dir, "*.types")].flat_map { |f| File.readlines(f, chomp: true, encoding: "UTF-8") }
      end
    end

    # rbs-trace (sinsoku/rbs-trace): runtime types, saved as RBS files.
    class RbsTrace < Base
      def run
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        run_tests(File.join(HOOKS, "rbs_trace.rb"),
                  "RBS_TRACE_PATHS" => config.lib_paths.join(":"), "RBS_TRACE_OUT" => dir)
      end

      def read
        rbs = RbsReader.read_files(Dir[File.join(dir, "**/*.rbs")])
        keep(rbs.methods.to_h { |k, sigs| [k, Evidence.new(source: name, sigs: sigs, calls: 1)] })
      end
    end

    # Lumitrace (ko1/lumitrace): per-expression types. Argument events are
    # matched to parameters, and the last expression of a method body to its
    # return value, by parsing the library with Prism.
    class Lumitrace < Base
      def run
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        root = config.lib_paths.first
        run_tests(File.join(HOOKS, "lumitrace.rb"),
                  "LUMITRACE_ROOT" => root, "LUMITRACE_OUT" => dir, "LUMITRACE_ENABLE" => nil)
      end

      def read
        defs = DefIndex.new(config.lib_paths)
        args = Hash.new { |h, k| h[k] = Hash.new(0) }
        exprs = Hash.new { |h, k| h[k] = Hash.new(0) }
        Dir[File.join(dir, "*.json")].each do |f|
          (JSON.parse(File.read(f, encoding: "UTF-8"))["events"] || []).each do |ev|
            types = ev["types"] || {}
            if ev["kind"] == "arg"
              types.each { |t, n| args[[ev["file"], ev["start_line"], ev["name"]]][t] += n }
            else
              loc = [ev["file"], ev["start_line"], ev["start_col"], ev["end_line"], ev["end_col"]]
              types.each { |t, n| exprs[loc][t] += n }
            end
          end
        end
        out = {}
        defs.each do |d|
          params = d[:params].map do |p|
            seen = args[[d[:file], p[:line], p[:name]]]
            { kind: p[:kind], name: p[:name], types: seen.keys.map { |t| lumi_type(t) }.uniq }
          end
          ret = d[:lasts].flat_map { |loc| exprs[loc].keys.map { |t| lumi_type(t) } }
          ret += (d[:falsy_lasts] || []).flat_map { |loc| exprs[loc].keys.map { |t| lumi_type(t) } & %w[nil bool] }
          ret += (d[:truthy_lasts] || []).flat_map { |loc| exprs[loc].keys.map { |t| lumi_type(t) } - ["nil"] }
          ret.uniq!
          # Calls: the most argument events of one parameter (each call
          # records every parameter once).
          calls = d[:params].map { |p| args[[d[:file], p[:line], p[:name]]].values.sum }.max || 0
          next if params.all? { |p| p[:types].empty? } && ret.empty?

          # Literals and `return a, b` leave no expression event: take their
          # types from the source, once the method is known to have run.
          ret |= d[:fixed_returns] || [] if calls.positive? || !ret.empty?
          ret |= ["nil"] if d[:implicit_nil] && !ret.empty?
          out[d[:key]] = Evidence.new(source: name, params: params.reject { |p| p[:kind] == "block" },
                                      block: params.any? { |p| p[:kind] == "block" } ? %w[no yes] : [],
                                      returns: ret, raises: [], calls: calls)
        end
        keep(out)
      end

      def lumi_type(t)
        { "NilClass" => "nil", "TrueClass" => "bool", "FalseClass" => "bool" }.fetch(t, t)
      end
    end

    # TypeProf: static inference over library (and test) files.
    class Typeprof < Base
      def run
        FileUtils.mkdir_p(config.out)
        files = (config.lib_paths + config.test_paths).map(&:shellescape).join(" ")
        sh({}, "#{tool_bin('typeprof')} --no-collection --show-parameter-names " \
               "--no-show-errors -o #{File.join(config.out, 'typeprof.rbs').shellescape} #{files}",
           chdir: config.repo, log: File.join(config.out, "typeprof.log"), tool: true)
      end

      def read = from_rbs(File.join(config.out, "typeprof.rbs"))

      def from_rbs(path)
        return {} unless File.exist?(path)

        rbs = RbsReader.read_files([path])
        keep(rbs.methods.to_h { |k, sigs| [k, Evidence.new(source: name, sigs: sigs)] })
      end

      def classes
        path = File.join(config.out, "#{name}.rbs")
        File.exist?(path) ? RbsReader.read_files([path]).classes : {}
      end
    end

    # tyda: static inference; with the tests it also sees call-site types.
    class Tyda < Typeprof
      def run
        FileUtils.mkdir_p(config.out)
        files = (config.lib_paths + config.test_paths).map(&:shellescape).join(" ")
        sh({}, "#{tool_bin('tyda')} #{files} > #{File.join(config.out, 'tyda.rbs').shellescape}",
           chdir: config.repo, log: File.join(config.out, "tyda.log"), tool: true)
      end

      def read = from_rbs(File.join(config.out, "tyda.rbs"))
    end

    # YARD documentation turned into RBS by Sord: the documented contract
    # (@param/@return), which tests may not exercise. Docs can be stale, so
    # this is compared, never trusted alone.
    class Yard < Typeprof
      def run
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        files = config.lib_paths.map { |d| File.join(d, "**", "*.rb").shellescape }.join(" ")
        out = File.join(config.out, "yard.rbs")
        sh({}, "#{tool_bin('yard')} doc -n -q --no-progress #{files} && " \
               "#{tool_bin('sord')} gen --rbs --hide-private --replace-errors-with-untyped " \
               "--no-sord-comments --no-regenerate #{out.shellescape}",
           chdir: dir, log: File.join(config.out, "yard.log"), tool: true)
      end

      def read = from_rbs(File.join(config.out, "yard.rbs"))
    end

    # Rigor (rigortype/rigor): inference-first static analyzer with an RBS
    # generator (`rigor sig-gen`). Needs Ruby 4.0: uses RIGOR_RUBY, or the
    # newest rbenv-installed Ruby 4.x, with rigortype installed in
    # RIGOR_GEM_HOME (default ~/.gem/rigor). Skipped when not available.
    class Rigor < Typeprof
      def ruby
        return ENV["RIGOR_RUBY"] if ENV["RIGOR_RUBY"]

        root = ENV["RBENV_ROOT"] || (`rbenv root 2>/dev/null`.strip rescue "")
        root = "/opt/rbenv" if root.empty? && Dir.exist?("/opt/rbenv")
        Dir[File.join(root, "versions", "4.*", "bin", "ruby")].max_by { |r| Gem::Version.new(r[%r{versions/([^/]+)/}, 1]) rescue Gem::Version.new("0") }
      end

      def home = ENV["RIGOR_GEM_HOME"] || File.join(Dir.home, ".gem", "rigor")
      def rigor_bin = File.join(home, "bin", "rigor")
      def available? = ruby && File.executable?(ruby) && File.exist?(rigor_bin)

      def run
        unless available?
          warn "rigor: skipped (no Ruby 4.0 with rigortype; see docs/evidence.md)"
          return false
        end
        FileUtils.mkdir_p(config.out)
        files = config.lib_paths.flat_map { |d| Dir[File.join(d, "**", "*.rb")] }.map(&:shellescape).join(" ")
        sh({ "GEM_HOME" => home, "GEM_PATH" => home, "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil },
           "#{ruby.shellescape} #{rigor_bin.shellescape} sig-gen --print --params=observed " \
           "#{config.test_paths.map { |t| "--observe=#{t.shellescape}" }.join(' ')} #{files} " \
           "> #{File.join(config.out, 'rigor.rbs').shellescape}",
           chdir: config.repo, log: File.join(config.out, "rigor.log"))
      end

      def read = from_rbs(File.join(config.out, "rigor.rbs"))
    end

    # rbs prototype runtime: the method list and parameter names/kinds of the
    # loaded gem; types are untyped. Runs in the gem's environment.
    class Prototype < Typeprof
      def run
        FileUtils.mkdir_p(config.out)
        # After the gem, load what it registered with `autoload` (classes
        # loaded lazily are otherwise missing from the prototype).
        eager = File.join(LIBEXEC, "eager_load.rb")
        reqs = (config.requires + [eager]).map { |r| "-r #{r.shellescape}" }.join(" ")
        pats = config.ns.flat_map { |n| [n, "#{n}::*"] }.map(&:shellescape).join(" ")
        # `rbs -I` is for signatures; the library goes on Ruby's load path.
        rubyopt = [config.lib_paths.map { |d| "-I#{d}" }, config.env["RUBYOPT"]].flatten.compact.join(" ")
        sh(config.env.merge("RUBYOPT" => rubyopt, "GEM_TYPES_EAGER_NS" => config.ns.join(","),
                            "GEM_TYPES_EAGER_LIB" => config.lib_paths.join(":")), "bundle exec rbs prototype runtime #{reqs} #{pats} " \
                       "> #{File.join(config.out, 'prototype.rbs').shellescape}",
           chdir: config.repo, log: File.join(config.out, "prototype.log"))
      end

      def read = from_rbs(File.join(config.out, "prototype.rbs"))
    end
  end

  # Index of `def`s in library files: key, parameters (with line), location
  # of the last expression of the body.
  class DefIndex
    include Enumerable

    # attrs: { key => { kind: "reader"|"writer"|"accessor", file:, line: } }
    #   from attr_* calls, Struct.new and Data.define members.
    # hidden: { key => reason } for private/protected methods and methods
    #   documented as internal (@api private, @private, :nodoc:).
    # privatized: [[module, other module], ...] for module bodies doing
    #   `private(*Other.instance_methods(false))` (see Lint.privatized_mixins).
    attr_reader :attrs, :hidden, :privatized

    def initialize(dirs)
      @defs = []
      @attrs = {}
      @hidden = {}
      @internal_ns = {}
      @privatized = []
      dirs.flat_map { |d| Dir[File.join(d, "**/*.rb")] }.select { |f| File.file?(f) }.each do |file|
        result = Prism.parse_file(file)
        # Comments on lines of their own form the doc block above a
        # definition; a trailing comment (`def x # :nodoc:`) belongs to the
        # definition on its own line only.
        @comments = {}
        @trailing = {}
        result.comments.each do |c|
          (c.trailing? ? @trailing : @comments)[c.location.start_line] = c.location.slice
        end
        visit(result.value, [], false, file)
        Lint.walk_private(result.value, [], @privatized)
      end
      @privatized.uniq!
    end

    def each(&) = @defs.each(&)

    private

    VISIBILITY = %i[private protected public].freeze
    ATTRS = { attr_reader: "reader", attr_writer: "writer", attr_accessor: "accessor", attr: "reader" }.freeze
    # Statements that do not open a new scope: a `private` inside them still
    # applies to the rest of the class body.
    TRANSPARENT = [Prism::IfNode, Prism::UnlessNode, Prism::ElseNode, Prism::BeginNode,
                   Prism::StatementsNode, Prism::ParenthesesNode].freeze

    # Visibility state of one class body.
    Section = Struct.new(:visibility, :module_function)

    def visit(node, ns, singleton, file)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = nest(ns, node.constant_path.slice)
        line = node.location.start_line
        @internal_ns[inner.join("::")] = true if internal_doc?(doc_above(line)) || internal_doc?(@trailing[line].to_s)
        struct_members(node.superclass, inner, file) if node.is_a?(Prism::ClassNode)
        node.body && visit_body(node.body, inner, false, file)
        return
      when Prism::SingletonClassNode
        # `class << self` and `class << Foo`: singleton methods of that module.
        target = receiver_ns(ns, node.expression)
        node.body && visit_body(node.body, target || ns, !target.nil?, file)
        return
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        name = node.is_a?(Prism::ConstantWriteNode) ? node.name.to_s : node.target.slice
        return if struct_members(node.value, nest(ns, name), file)
      when Prism::DefNode
        def_node(node, ns, singleton, file)
        return
      end
      node.compact_child_nodes.each { |c| visit(c, ns, singleton, file) }
    end

    # `def x` / `def self.x` / `def Const.x`: any receiver makes it a
    # singleton method (of the named module when it is one we can resolve).
    def def_node(node, ns, singleton, file)
      return add_def(node, ns, singleton, file) unless node.receiver

      add_def(node, receiver_ns(ns, node.receiver) || ns, true, file)
    end

    # The namespace a `self` / constant expression refers to, or nil when it
    # is something else (a local variable, a method call).
    def receiver_ns(ns, expr)
      case expr
      when Prism::SelfNode then ns
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        name = expr.slice
        return [name.delete_prefix("::")] if name.start_with?("::")

        parts = name.split("::")
        return ns if parts.size <= ns.size && ns.last(parts.size) == parts

        nest(ns, name)
      end
    end

    # The full name of `class Name` written inside `ns`. A qualified name
    # whose first part is one of the enclosing modules resolves from there
    # (`module IPAddress; class IPAddress::IPv6::Mapped` is
    # IPAddress::IPv6::Mapped, not IPAddress::IPAddress::IPv6::Mapped).
    def nest(ns, name)
      return [name.delete_prefix("::")] if name.start_with?("::")

      first = name.split("::").first
      i = ns.rindex(first)
      i && name.include?("::") ? ns[0...i] + [name] : ns + [name]
    end

    # A class body in order, tracking `private` / `module_function` sections.
    def visit_body(body, ns, singleton, file, section = Section.new(:public, false))
      stmts = case body
              when Prism::StatementsNode then body.body
              when Prism::BeginNode then body.statements&.body || []
              else [body]
              end
      stmts.each { |st| statement(st, ns, singleton, file, section) }
    end

    # One statement of a class body. Returns the names of the methods it
    # defines (for `private memoize def x` and the like).
    def statement(st, ns, singleton, file, section)
      if st.is_a?(Prism::CallNode) && st.receiver.nil?
        args = st.arguments&.arguments || []
        if VISIBILITY.include?(st.name)
          if args.empty?
            section.visibility = st.name
            section.module_function = false
          else
            args.each { |a| wrapped(a, ns, singleton, file).each { |n| hide(ns, singleton, n, st.name) } }
          end
          return []
        elsif st.name == :private_class_method
          args.each do |a|
            names = a.is_a?(Prism::DefNode) ? (add_def(a, ns, true, file); [a.name]) : wrapped(a, ns, true, file)
            names.each { |n| hide(ns, true, n, :private) }
          end
          return []
        elsif st.name == :module_function
          if args.empty?
            section.module_function = true
          else
            args.each do |a|
              if a.is_a?(Prism::DefNode)
                add_def(a, ns, false, file)
                add_def(a, ns, true, file)
                hide(ns, false, a.name, :module_function)
              else
                wrapped(a, ns, false, file).each do |n|
                  copy_to_singleton(ns, n)
                  hide(ns, false, n, :module_function)
                end
              end
            end
          end
          return []
        elsif ATTRS.key?(st.name)
          names = []
          args.each do |a|
            next unless a.respond_to?(:unescaped)

            add_attr(ns, singleton, a.unescaped, ATTRS[st.name], file, st.location.start_line)
            hide(ns, singleton, a.unescaped, section.visibility) unless section.visibility == :public
            names << a.unescaped
          end
          return names
        end
      end
      case st
      when Prism::DefNode
        def_node(st, ns, singleton, file)
        if st.receiver
          # visibility sections do not apply to `def self.x`
        elsif section.module_function && !singleton
          add_def(st, ns, true, file)
          hide(ns, false, st.name, :module_function)
        elsif section.visibility != :public
          hide(ns, singleton, st.name, section.visibility)
        end
        [st.name]
      when *TRANSPARENT
        names = []
        st.compact_child_nodes.each do |c|
          if c.is_a?(Prism::StatementsNode)
            c.body.each { |x| names.concat(statement(x, ns, singleton, file, section)) }
          elsif TRANSPARENT.include?(c.class)
            names.concat(statement(c, ns, singleton, file, section))
          else
            visit(c, ns, singleton, file)
          end
        end
        names
      else
        visit(st, ns, singleton, file)
        defined_names(st)
      end
    end

    # The argument of `private x` / `module_function x`: a Symbol or String
    # names a method; a def or a call wrapping one (`private memoize def x`,
    # `private attr_reader :x`) is indexed and its names returned.
    def wrapped(arg, ns, singleton, file)
      case arg
      when Prism::SymbolNode, Prism::StringNode then [arg.unescaped]
      when Prism::DefNode
        add_def(arg, ns, singleton, file)
        [arg.name]
      when Prism::ArrayNode then arg.elements.flat_map { |e| wrapped(e, ns, singleton, file) }
      else
        statement(arg, ns, singleton, file, Section.new(:public, false))
      end
    end

    # Method names defined by defs and attr_* calls inside a node (not inside
    # nested classes or modules).
    def defined_names(node)
      out = []
      stack = [node]
      while (n = stack.pop)
        case n
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then next
        when Prism::DefNode then out << n.name.to_s
        when Prism::CallNode
          if n.receiver.nil? && ATTRS.key?(n.name)
            (n.arguments&.arguments || []).each { |a| out << a.unescaped if a.respond_to?(:unescaped) }
          end
        end
        stack.concat(n.compact_child_nodes) unless n.is_a?(Prism::DefNode)
      end
      out
    end

    # `module_function :x`: x also becomes a singleton method.
    def copy_to_singleton(ns, name)
      return if ns.empty?

      base = "#{ns.join('::')}##{name}"
      d = @defs.reverse_each.find { |x| x[:key] == base } or return
      skey = "#{ns.join('::')}.#{name}"
      @defs << d.merge(key: skey) unless @defs.any? { |x| x[:key] == skey }
    end

    def struct_members(node, ns, file)
      return unless node.is_a?(Prism::CallNode) && node.receiver
      recv = node.receiver.slice.delete_prefix("::")
      kind = { %w[Struct new] => "accessor", %w[Data define] => "reader" }[[recv, node.name.to_s]]
      # `K = Class.new do ... end`: the block is K's body.
      kind ||= :body if %w[Class Module].include?(recv) && node.name == :new && node.block.is_a?(Prism::BlockNode)
      return unless kind

      unless kind == :body
        (node.arguments&.arguments || []).each do |a|
          add_attr(ns, false, a.unescaped, kind, file, node.location.start_line) if a.is_a?(Prism::SymbolNode)
        end
      end
      blk = node.block
      blk.body && visit_body(blk.body, ns, false, file) if blk.is_a?(Prism::BlockNode)
      true
    end

    def add_attr(ns, singleton, name, kind, file, line)
      return if ns.empty?

      base = "#{ns.join('::')}#{singleton ? '.' : '#'}#{name}"
      @attrs[base] = { kind: kind, file: file, line: line }
      if internal_ns?(ns) || internal_doc?(@trailing[line].to_s)
        @hidden[base] ||= "documented as internal"
        @hidden["#{base}="] ||= "documented as internal" unless kind == "reader"
      end
    end

    def hide(ns, singleton, name, reason)
      return if ns.empty? || reason == :public || name.to_s == "initialize"

      key = "#{ns.join('::')}#{singleton ? '.' : '#'}#{name}"
      @hidden[key] = reason.to_s
      @hidden["#{key}="] = reason.to_s if @attrs[key] && @attrs[key][:kind] != "reader"
    end

    def internal_doc?(doc) = doc.match?(/@api\s+private|@private\b|:nodoc:/)

    def internal_ns?(ns)
      ns.each_index.any? { |i| @internal_ns[ns[0..i].join("::")] }
    end

    # The comment block right above a line (comments on lines of their own).
    def doc_above(line)
      out = []
      l = line - 1
      while (c = @comments[l])
        out.unshift(c)
        l -= 1
      end
      out.join("\n")
    end

    def add_def(node, ns, singleton, file)
      return if ns.empty?

      key = "#{ns.join('::')}#{singleton ? '.' : '#'}#{node.name}"
      line = node.location.start_line
      if internal_doc?(doc_above(line)) || internal_doc?(@trailing[line].to_s) || internal_ns?(ns)
        @hidden[key] ||= "documented as internal"
      end
      params = []
      if (p = node.parameters)
        p.requireds.each { |x| params << param(x, "req") }
        p.optionals.each { |x| params << param(x, "opt") }
        params << param(p.rest, "rest") if p.rest.respond_to?(:name) && p.rest.name
        p.posts.each { |x| params << param(x, "req") }
        p.keywords.each { |x| params << param(x, x.is_a?(Prism::RequiredKeywordParameterNode) ? "keyreq" : "key") }
        params << param(p.keyword_rest, "keyrest") if p.keyword_rest.respond_to?(:name) && p.keyword_rest.name
        params << param(p.block, "block") if p.block&.name
      end
      tails, implicit_nil, fixed = tail_exprs(node.body)
      loc = ->(t) { l = t.location; [file, l.start_line, l.start_column, l.end_line, l.end_column] }
      # lasts: the value is returned; falsy_lasts / truthy_lasts: only when
      # falsy / truthy (the left side of && / ||).
      lasts, filtered = tails.partition { |t| !t.is_a?(Array) }
      @defs << { key: key, file: file, line: line, end_line: node.location.end_line,
                 params: params.compact, lasts: lasts.map(&loc), implicit_nil: implicit_nil, fixed_returns: fixed.uniq,
                 falsy_lasts: filtered.filter_map { |n, f| loc.(n) if f == :falsy },
                 truthy_lasts: filtered.filter_map { |n, f| loc.(n) if f == :truthy },
                 legacy_consts: legacy_consts(node.body), early_nil: early_nil?(node.body), shape: shape(node.parameters),
                 block: block_usage(node, params.compact.find { |x| x[:kind] == "block" }&.dig(:name)) }
    end

    # Every parameter of a def in order, anonymous ones included (`*`, `**`,
    # `&`, destructuring `(a, b)`), as { kind:, name: } with kinds req, opt,
    # rest, post (required after the rest), keyreq, key, keyrest, block,
    # fwd (`...`) and nokey (`**nil`). name is nil when there is none.
    def shape(p)
      return [] unless p

      name = ->(x) { x.respond_to?(:name) && x.name ? x.name.to_s : nil }
      out = p.requireds.map { |x| { kind: "req", name: name.(x) } }
      out.concat(p.optionals.map { |x| { kind: "opt", name: name.(x) } })
      out << { kind: "rest", name: name.(p.rest) } if p.rest.is_a?(Prism::RestParameterNode)
      out.concat(p.posts.map { |x| { kind: "post", name: name.(x) } })
      p.keywords.each { |x| out << { kind: x.is_a?(Prism::RequiredKeywordParameterNode) ? "keyreq" : "key", name: name.(x) } }
      case p.keyword_rest
      when Prism::KeywordRestParameterNode then out << { kind: "keyrest", name: name.(p.keyword_rest) }
      when Prism::ForwardingParameterNode then out << { kind: "fwd", name: nil }
      when Prism::NoKeywordsParameterNode then out << { kind: "nokey", name: nil }
      end
      out << { kind: "block", name: name.(p.block) } if p.block
      out
    end

    # A `return` / `return nil` anywhere in the body (not in a nested def
    # or lambda, whose return is their own).
    def early_nil?(body)
      stack = [body].compact
      while (n = stack.pop)
        next if n.is_a?(Prism::DefNode) || n.is_a?(Prism::LambdaNode)
        next if n.is_a?(Prism::CallNode) && n.name == :lambda && n.receiver.nil?

        if n.is_a?(Prism::ReturnNode)
          args = n.arguments&.arguments || []
          return true if args.empty? || (args.size == 1 && args.first.is_a?(Prism::NilNode))
        end
        stack.concat(n.compact_child_nodes)
      end
      false
    end

    # An `unless block_given?` / `unless blk` / `if !blk` / `if blk.nil?`
    # whose body raises.
    def raise_without_block?(n, blk)
      return false unless n.is_a?(Prism::IfNode) || n.is_a?(Prism::UnlessNode)

      c = n.predicate
      given = lambda do |x|
        (x.is_a?(Prism::CallNode) && x.receiver.nil? && %i[block_given? iterator?].include?(x.name)) ||
          (blk && x.is_a?(Prism::LocalVariableReadNode) && x.name == blk)
      end
      missing = if n.is_a?(Prism::UnlessNode) then given.(c)
                elsif c.is_a?(Prism::CallNode) && c.name == :! then given.(c.receiver)
                elsif c.is_a?(Prism::CallNode) && c.name == :nil? then c.receiver && given.(c.receiver)
                else false
                end
      return false unless missing

      body = n.statements&.body || []
      body.size == 1 && body.first.is_a?(Prism::CallNode) && %i[raise fail].include?(body.first.name) && body.first.receiver.nil?
    end

    # Methods whose block runs with another self (DSL blocks need
    # `[self: X]` in the RBS).
    SELF_CHANGING = %i[instance_eval instance_exec class_eval class_exec module_eval module_exec
                       define_method define_singleton_method].freeze

    # How a method body uses its block:
    #   yields:     argument counts of `yield` / `blk.call` (nil: splat)
    #   guarded:    block_given? or `if blk` / `blk&.call` / `blk.nil?`
    #   forwarded:  passed on with `&blk` (or `&`), or by `super` (with or without arguments)
    #   stored:     kept for later (`@x = blk`, passed as an argument)
    #   enum:       calls to_enum / enum_for (returns an Enumerator without one)
    #   self_eval:  passed to instance_eval/instance_exec/... (DSL block)
    #   self_on:    the self type that block runs with (see #self_on)
    def block_usage(defn, name)
      u = { yields: [], guarded: false, forwarded: false, stored: false, enum: false, self_eval: false, named: !name.nil? }
      blk = name&.to_sym
      stack = [defn.body].compact
      while (n = stack.pop)
        case n
        when Prism::DefNode then next
        when Prism::YieldNode
          args = n.arguments&.arguments || []
          u[:yields] << (args.any? { |a| a.is_a?(Prism::SplatNode) } ? nil : args.size)
        when Prism::ForwardingSuperNode then u[:forwarded] = u[:super] = true
        when Prism::SuperNode
          # `super(a)` passes the method's block on as well.
          u[:forwarded] = u[:super] = true unless n.block.is_a?(Prism::BlockNode)
        when Prism::CallNode
          if n.receiver.nil? && %i[block_given? iterator?].include?(n.name)
            u[:guarded] = true
          elsif n.receiver.nil? && %i[to_enum enum_for].include?(n.name) ||
                n.receiver.is_a?(Prism::SelfNode) && %i[to_enum enum_for].include?(n.name)
            u[:enum] = true
          end
          if blk && n.receiver.is_a?(Prism::LocalVariableReadNode) && n.receiver.name == blk
            if %i[call yield () []].include?(n.name)
              args = n.arguments&.arguments || []
              u[:yields] << (args.any? { |a| a.is_a?(Prism::SplatNode) } ? nil : args.size)
              u[:guarded] = true if n.safe_navigation?
            elsif %i[nil? present? blank?].include?(n.name)
              u[:guarded] = true
            end
          end
          ba = n.block
          if ba.is_a?(Prism::BlockArgumentNode) && (ba.expression.nil? || ba.expression.is_a?(Prism::LocalVariableReadNode) && ba.expression.name == blk)
            if SELF_CHANGING.include?(n.name) || n.name == :new && n.receiver&.slice == "Class"
              u[:self_eval] = true
              u[:self_on] ||= self_on(n)
            else
              u[:forwarded] = true
              (u[:forward_to] ||= []) << n.name.to_s
            end
          end
          if blk && (n.arguments&.arguments || []).any? { |a| a.is_a?(Prism::LocalVariableReadNode) && a.name == blk }
            if SELF_CHANGING.include?(n.name)
              u[:self_eval] = true
              u[:self_on] ||= self_on(n)
            else
              u[:stored] = true
            end
          end
        when Prism::IfNode, Prism::UnlessNode, Prism::AndNode, Prism::OrNode
          cond = n.respond_to?(:predicate) ? n.predicate : n.left
          u[:guarded] = true if blk && cond.is_a?(Prism::LocalVariableReadNode) && cond.name == blk
          # `raise ArgumentError, "needs a block" unless block_given?`: the
          # check makes the block required, not optional.
          if raise_without_block?(n, blk)
            u[:requires] = true
          end
        when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::LocalVariableWriteNode,
             Prism::ClassVariableWriteNode, Prism::ConstantWriteNode
          u[:stored] = true if blk && n.value.is_a?(Prism::LocalVariableReadNode) && n.value.name == blk
        when Prism::HashNode, Prism::ArrayNode, Prism::KeywordHashNode
          elems = n.respond_to?(:elements) ? n.elements : []
          vals = elems.map { |e| e.respond_to?(:value) ? e.value : e }
          u[:stored] = true if blk && vals.any? { |v| v.is_a?(Prism::LocalVariableReadNode) && v.name == blk }
        end
        stack.concat(n.compact_child_nodes)
      end
      u
    end

    # The self a block passed to `call` runs with, as an RBS type for its
    # `[self: X]`: `self` for instance_eval/class_eval on the receiver,
    # `instance` for define_method, `Foo` for `Foo.new.instance_eval`,
    # `singleton(Foo)` for `Foo.instance_eval`, `Class` for `Class.new`,
    # untyped otherwise.
    def self_on(call)
      return "Class" if call.name == :new
      return "instance" if %i[define_method].include?(call.name) && (call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode))

      r = call.receiver
      case r
      when nil, Prism::SelfNode then "self"
      when Prism::ConstantReadNode, Prism::ConstantPathNode then "singleton(#{r.slice})"
      when Prism::CallNode
        r.name == :new && (r.receiver.is_a?(Prism::ConstantReadNode) || r.receiver.is_a?(Prism::ConstantPathNode)) ? r.receiver.slice : "untyped"
      else "untyped"
      end
    end

    # Types of literal nodes Lumitrace does not record a value for.
    LITERALS = {
      Prism::NilNode => "nil", Prism::TrueNode => "bool", Prism::FalseNode => "bool",
      Prism::IntegerNode => "Integer", Prism::FloatNode => "Float", Prism::RationalNode => "Rational",
      Prism::StringNode => "String", Prism::InterpolatedStringNode => "String", Prism::XStringNode => "String",
      Prism::SymbolNode => "Symbol", Prism::InterpolatedSymbolNode => "Symbol",
      Prism::RegularExpressionNode => "Regexp", Prism::InterpolatedRegularExpressionNode => "Regexp",
      Prism::RangeNode => "Range[untyped]", Prism::ArrayNode => "Array[untyped]", Prism::HashNode => "Hash[untyped, untyped]",
      Prism::SelfNode => nil
    }.freeze

    # The expressions whose value a method body can return (Lumitrace does
    # not record values of if/case/begin themselves, only of what is inside),
    # whether some path returns nil implicitly, and return types known from
    # the source alone (literals, `return a, b`).
    # Returns [nodes, implicit_nil, fixed_types].
    def tail_exprs(node)
      case node
      when nil then [[], true, []]
      when Prism::StatementsNode then tail_exprs(node.body.last)
      when Prism::ParenthesesNode then tail_exprs(node.body)
      when Prism::BeginNode
        return [[], true, []] if node.statements.nil? && node.rescue_clause.nil?
        parts = [node.else_clause ? tail_exprs(node.else_clause.statements) : tail_exprs(node.statements)]
        r = node.rescue_clause
        while r
          parts << tail_exprs(r.statements)
          r = r.subsequent
        end
        combine(parts)
      when Prism::IfNode, Prism::UnlessNode
        alt = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        combine([tail_exprs(node.statements),
                 alt ? tail_exprs(alt.is_a?(Prism::ElseNode) ? alt.statements : alt) : [[], true, []]])
      when Prism::ElseNode then tail_exprs(node.statements)
      when Prism::CaseNode, Prism::CaseMatchNode
        parts = node.conditions.map { |w| tail_exprs(w.statements) }
        # case/in without else raises NoMatchingPatternError instead.
        parts << (node.else_clause ? tail_exprs(node.else_clause.statements) : [[], node.is_a?(Prism::CaseNode), []])
        combine(parts)
      when Prism::ReturnNode
        args = node.arguments&.arguments || []
        if args.empty? then [[], true, []]
        elsif args.size > 1 || args.first.is_a?(Prism::SplatNode) then [[], false, ["Array[untyped]"]]
        else tail_exprs(args.first)
        end
      when Prism::AndNode, Prism::OrNode
        # `a && b` returns a only when a is falsy, `a || b` only when truthy.
        l_nodes, l_nil, l_fixed = tail_exprs(node.left)
        filter = node.is_a?(Prism::AndNode) ? :falsy : :truthy
        l_fixed = l_fixed.select { |t| filter == :falsy ? %w[nil bool].include?(t) : t != "nil" }
        combine([[l_nodes.map { |n| n.is_a?(Array) ? n : [n, filter] }, l_nil && filter == :falsy, l_fixed],
                 tail_exprs(node.right)])
      else
        if LITERALS.key?(node.class)
          t = LITERALS[node.class]
          t ? [[node], false, [t]] : [[node], false, []]
        elsif node.class.name.match?(/(?<!Operator)WriteNode\z/) && node.respond_to?(:value)
          # `x = v`, `@m ||= v`, `a, b = v`: the value of v.
          tail_exprs(node.value)
        else [[node], false, []]
        end
      end
    rescue NoMethodError
      [[node], false, []]
    end

    def combine(parts) = [parts.flat_map(&:first), parts.any? { _1[1] }, parts.flat_map(&:last)]

    # Constants removed from Ruby that a method body still refers to
    # (a reference raises NameError on Ruby 3.2 and later).
    LEGACY = %i[Fixnum Bignum].freeze

    def legacy_consts(node)
      return [] unless node

      found = []
      stack = [node]
      while (n = stack.pop)
        found << n.name if n.is_a?(Prism::ConstantReadNode) && LEGACY.include?(n.name)
        stack.concat(n.compact_child_nodes)
      end
      found.uniq.map(&:to_s)
    end

    def param(node, kind)
      return nil unless node.respond_to?(:name) && node.name

      loc = node.respond_to?(:name_loc) && node.name_loc ? node.name_loc : node.location
      h = { kind: kind, name: node.name.to_s, line: loc.start_line }
      # `opts = {}`: an options Hash passed positionally.
      h[:hash_default] = true if node.respond_to?(:value) && node.value.is_a?(Prism::HashNode)
      h
    end
  end
end
