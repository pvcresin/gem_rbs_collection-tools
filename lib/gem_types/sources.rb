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
        ok = system(full, "bash", "-c", cmd, chdir: chdir, out: log, err: %i[child out], unsetenv_others: true)
        warn "#{name}: command failed (see #{log})" unless ok
        ok
      end

      def tool_bin(gem, exe = gem) = "#{RbConfig.ruby.shellescape} #{Gem.bin_path(gem, exe).shellescape}"

      # Runs the test command with an extra -r hook.
      def run_tests(hook, env)
        raise "#{name}: --test-cmd is required" unless config.test_cmd

        rubyopt = ["-r#{hook}", config.env["RUBYOPT"], ENV.fetch("RUBYOPT", nil)].compact.join(" ")
        # `bundle exec rspec` normally loads rspec inside the bundle process,
        # where the hooks have skipped themselves; make it exec instead.
        full = config.env.merge(env).merge("RUBYOPT" => rubyopt, "BUNDLE_DISABLE_EXEC_LOAD" => "true")
        ok = sh(full, config.test_cmd, chdir: config.repo, log: File.join(config.out, "#{name}.log"))
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
              p = e.params.find { |x| x[:name] == pname } || (e.params << { kind: kind, name: pname, types: [] }).last
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
          ret = d[:lasts].flat_map { |loc| exprs[loc].keys.map { |t| lumi_type(t) } }.uniq
          ret |= ["nil"] if d[:implicit_nil] && !ret.empty?
          next if params.all? { |p| p[:types].empty? } && ret.empty?

          calls = params.map { |p| args[[d[:file], p[:line], p[:name]]].values.sum }.max || 0
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
        reqs = config.requires.map { |r| "-r #{r.shellescape}" }.join(" ")
        pats = config.ns.flat_map { |n| [n, "#{n}::*"] }.map(&:shellescape).join(" ")
        # `rbs -I` is for signatures; the library goes on Ruby's load path.
        rubyopt = [config.lib_paths.map { |d| "-I#{d}" }, config.env["RUBYOPT"]].flatten.compact.join(" ")
        sh(config.env.merge("RUBYOPT" => rubyopt), "bundle exec rbs prototype runtime #{reqs} #{pats} " \
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
    attr_reader :attrs, :hidden

    def initialize(dirs)
      @defs = []
      @attrs = {}
      @hidden = {}
      dirs.flat_map { |d| Dir[File.join(d, "**/*.rb")] }.each do |file|
        result = Prism.parse_file(file)
        @comments = result.comments.to_h { |c| [c.location.start_line, c.location.slice] }
        visit(result.value, [], false, file)
      end
    end

    def each(&) = @defs.each(&)

    private

    VISIBILITY = %i[private protected public].freeze
    ATTRS = { attr_reader: "reader", attr_writer: "writer", attr_accessor: "accessor", attr: "reader" }.freeze

    def visit(node, ns, singleton, file)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = nest(ns, node.constant_path.slice)
        @internal_ns ||= {}
        @internal_ns[inner.join("::")] = true if internal_doc?(doc_above(node.location.start_line))
        struct_members(node.superclass, inner, file) if node.is_a?(Prism::ClassNode)
        node.body && visit_body(node.body, inner, false, file)
        return
      when Prism::SingletonClassNode
        node.body && visit_body(node.body, ns, node.expression.is_a?(Prism::SelfNode), file)
        return
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        name = node.is_a?(Prism::ConstantWriteNode) ? node.name.to_s : node.target.slice
        return if struct_members(node.value, nest(ns, name), file)
      when Prism::DefNode
        add_def(node, ns, singleton || node.receiver.is_a?(Prism::SelfNode), file)
        return
      end
      node.compact_child_nodes.each { |c| visit(c, ns, singleton, file) }
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
    def visit_body(body, ns, singleton, file)
      stmts = body.is_a?(Prism::StatementsNode) ? body.body : [body]
      stmts = body.statements&.body || [] if body.is_a?(Prism::BeginNode)
      section = :public
      module_function = false
      stmts.each do |st|
        if st.is_a?(Prism::CallNode) && st.receiver.nil?
          args = st.arguments&.arguments || []
          if VISIBILITY.include?(st.name)
            if args.empty?
              section = st.name
            else
              args.each do |a|
                if a.is_a?(Prism::DefNode)
                  add_def(a, ns, singleton || a.receiver.is_a?(Prism::SelfNode), file)
                  hide(ns, singleton, a.name, st.name)
                elsif a.respond_to?(:unescaped)
                  hide(ns, singleton, a.unescaped, st.name)
                end
              end
            end
            next
          elsif st.name == :private_class_method
            args.each { |a| hide(ns, true, a.is_a?(Prism::DefNode) ? a.name : a.unescaped, :private) if a.is_a?(Prism::DefNode) || a.respond_to?(:unescaped) }
            args.grep(Prism::DefNode).each { |a| add_def(a, ns, true, file) }
            next
          elsif st.name == :module_function
            if args.empty?
              module_function = true
            else
              args.each { |a| hide(ns, false, a.unescaped, :module_function) if a.respond_to?(:unescaped) }
            end
            next
          elsif ATTRS.key?(st.name)
            args.each do |a|
              next unless a.respond_to?(:unescaped)

              add_attr(ns, singleton, a.unescaped, ATTRS[st.name], file, st.location.start_line)
              hide(ns, singleton, a.unescaped, section) unless section == :public
            end
            next
          end
        end
        if st.is_a?(Prism::DefNode)
          sing = singleton || st.receiver.is_a?(Prism::SelfNode)
          add_def(st, ns, sing, file)
          if module_function && !sing
            add_def(st, ns, true, file)
            hide(ns, false, st.name, :module_function)
          elsif section != :public && !st.receiver
            hide(ns, singleton, st.name, section)
          end
        else
          visit(st, ns, singleton, file)
        end
      end
    end

    def struct_members(node, ns, file)
      return unless node.is_a?(Prism::CallNode) && node.receiver
      kind = { %w[Struct new] => "accessor", %w[Data define] => "reader" }[[node.receiver.slice.delete_prefix("::"), node.name.to_s]]
      return unless kind

      (node.arguments&.arguments || []).each do |a|
        add_attr(ns, false, a.unescaped, kind, file, node.location.start_line) if a.is_a?(Prism::SymbolNode)
      end
      node.block&.body && visit_body(node.block.body, ns, false, file)
      true
    end

    def add_attr(ns, singleton, name, kind, file, line)
      return if ns.empty?

      base = "#{ns.join('::')}#{singleton ? '.' : '#'}#{name}"
      @attrs[base] = { kind: kind, file: file, line: line }
      if internal_ns?(ns)
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
      return false unless @internal_ns

      ns.each_index.any? { |i| @internal_ns[ns[0..i].join("::")] }
    end

    # The comment block right above a line.
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
      @hidden[key] ||= "documented as internal" if internal_doc?(doc_above(node.location.start_line)) || internal_ns?(ns)
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
      tails, implicit_nil = tail_exprs(node.body)
      lasts = tails.map { |t| l = t.location; [file, l.start_line, l.start_column, l.end_line, l.end_column] }
      @defs << { key: key, file: file, line: node.location.start_line, end_line: node.location.end_line,
                 params: params.compact, lasts: lasts, implicit_nil: implicit_nil,
                 legacy_consts: legacy_consts(node.body) }
    end

    # The expressions whose value a method body can return (Lumitrace does
    # not record values of if/case/begin themselves, only of what is inside),
    # and whether some path returns nil implicitly.
    def tail_exprs(node)
      case node
      when nil then [[], true]
      when Prism::StatementsNode then tail_exprs(node.body.last)
      when Prism::ParenthesesNode then tail_exprs(node.body)
      when Prism::BeginNode
        return [[], true] if node.statements.nil?
        tail_exprs(node.else_clause ? node.else_clause.statements : node.statements)
      when Prism::IfNode, Prism::UnlessNode
        a, an = tail_exprs(node.statements)
        alt = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        b, bn = alt ? tail_exprs(alt.is_a?(Prism::ElseNode) ? alt.statements : alt) : [[], true]
        [a + b, an || bn]
      when Prism::ElseNode then tail_exprs(node.statements)
      when Prism::CaseNode
        parts = node.conditions.map { |w| tail_exprs(w.statements) }
        parts << (node.else_clause ? tail_exprs(node.else_clause.statements) : [[], true])
        [parts.flat_map(&:first), parts.any?(&:last)]
      when Prism::ReturnNode
        node.arguments ? [node.arguments.arguments, false] : [[], true]
      else [[node], false]
      end
    rescue NoMethodError
      [[node], false]
    end

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
