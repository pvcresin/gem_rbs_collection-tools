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
    STATIC = %w[typeprof tyda prototype].freeze
    ALL = (RUNTIME + STATIC).freeze

    def self.for(name, config) = const_get(name.split("_").map(&:capitalize).join).new(config)

    class Base
      attr_reader :config

      def initialize(config) = @config = config
      def name = self.class.name.split("::").last.gsub(/(?<!^)([A-Z])/, '_\1').downcase
      def dir = File.join(config.out, name)

      # Runs a command outside this tool's own bundle.
      def sh(env, cmd, chdir:, log:)
        FileUtils.mkdir_p(File.dirname(log))
        ok = nil
        clean = defined?(Bundler) ? Bundler.method(:with_unbundled_env) : ->(&b) { b.call }
        clean.call do
          ok = system(env, "bash", "-c", cmd, chdir: chdir, out: log, err: %i[child out])
        end
        warn "#{name}: command failed (see #{log})" unless ok
        ok
      end

      # Runs the test command with an extra -r hook.
      def run_tests(hook, env)
        raise "#{name}: --test-cmd is required" unless config.test_cmd

        rubyopt = ["-r#{hook}", config.env["RUBYOPT"], ENV.fetch("RUBYOPT", nil)].compact.join(" ")
        sh(config.env.merge(env).merge("RUBYOPT" => rubyopt), config.test_cmd,
           chdir: config.repo, log: File.join(config.out, "#{name}.log"))
      end

      def keep(hash) = hash.select { |k, _| config.in_ns?(k) }
    end

    # Our own TracePoint hook: per call shape, normal vs raising calls.
    class Tracepoint < Base
      def run
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        run_tests(File.join(HOOKS, "observe.rb"),
                  "OBSERVE_DIR" => dir, "OBSERVE_NS" => config.ns.flat_map { |n| [n, "#{n}::*"] }.join(","))
      end

      def read
        out = {}
        Dir[File.join(dir, "*.json")].each do |f|
          JSON.parse(File.read(f)).each do |key, d|
            e = out[key] ||= Evidence.new(source: name, params: [], block: [], returns: [], raises: [], calls: 0)
            e.calls += d["calls"]
            e.block |= d["block"]
            e.returns |= d["returns"]
            e.raises |= d["raises"].map { |r| r.delete_prefix("raise ") }
            d["kinds"].each do |label, (kind, pname)|
              p = e.params.find { |x| x[:name] == pname } || (e.params << { kind: kind, name: pname, types: [] }).last
              p[:types] |= d["params"][label] || []
            end
          end
        end
        out.each_value { |e| e.params = nil if e.params.empty? && e.returns.empty? }
        keep(out)
      end

      # The human-readable per-shape files, for the report.
      def shapes
        Dir[File.join(dir, "*.types")].flat_map { |f| File.readlines(f, chomp: true) }
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
          (JSON.parse(File.read(f))["events"] || []).each do |ev|
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
        bin = Gem.bin_path("typeprof", "typeprof")
        files = (config.lib_paths + config.test_paths).map(&:shellescape).join(" ")
        sh({}, "#{RbConfig.ruby.shellescape} #{bin.shellescape} --no-collection --show-parameter-names " \
               "--no-show-errors -o #{File.join(config.out, 'typeprof.rbs').shellescape} #{files}",
           chdir: config.repo, log: File.join(config.out, "typeprof.log"))
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
        bin = Gem.bin_path("tyda", "tyda")
        files = (config.lib_paths + config.test_paths).map(&:shellescape).join(" ")
        sh({}, "#{bin.shellescape} #{files} > #{File.join(config.out, 'tyda.rbs').shellescape}",
           chdir: config.repo, log: File.join(config.out, "tyda.log"))
      end

      def read = from_rbs(File.join(config.out, "tyda.rbs"))
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

    def initialize(dirs)
      @defs = []
      dirs.flat_map { |d| Dir[File.join(d, "**/*.rb")] }.each do |file|
        result = Prism.parse_file(file)
        visit(result.value, [], false, file)
      end
    end

    def each(&) = @defs.each(&)

    private

    def visit(node, ns, singleton, file)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        name = node.constant_path.slice
        inner = name.start_with?("::") ? [name.delete_prefix("::")] : ns + [name]
        node.body && visit(node.body, inner, false, file)
        return
      when Prism::SingletonClassNode
        node.body && visit(node.body, ns, node.expression.is_a?(Prism::SelfNode), file)
        return
      when Prism::DefNode
        add_def(node, ns, singleton || node.receiver.is_a?(Prism::SelfNode), file)
        return
      end
      node.compact_child_nodes.each { |c| visit(c, ns, singleton, file) }
    end

    def add_def(node, ns, singleton, file)
      return if ns.empty?

      key = "#{ns.join('::')}#{singleton ? '.' : '#'}#{node.name}"
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
      @defs << { key: key, file: file, params: params.compact, lasts: lasts, implicit_nil: implicit_nil }
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

    def param(node, kind)
      return nil unless node.respond_to?(:name) && node.name

      loc = node.respond_to?(:name_loc) && node.name_loc ? node.name_loc : node.location
      { kind: kind, name: node.name.to_s, line: loc.start_line }
    end
  end
end
