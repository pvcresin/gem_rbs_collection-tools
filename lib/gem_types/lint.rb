# frozen_string_literal: true

require "rbs"
require "prism"
require "yaml"

module GemTypes
  # Checks an RBS against the gem's source for the mistakes that later
  # commits in gem_rbs_collection most often had to fix (an analysis of
  # ~500 correcting commits): required vs optional blocks, yield arity, DSL
  # blocks without `[self: X]`, arity and keywords, missing nil, literal
  # types left by generators, protocol methods (==, hash, to_s, ...),
  # module_function, stubs of other libraries and the test/manifest
  # conventions. Every finding is [key, message]; none needs the gem loaded.
  module Lint
    module_function

    # One method declaration: key "A::B#m" / "A::B.m", its overloads
    # (RBS::MethodType) and whether it is `def self?.`.
    Decl = Struct.new(:key, :overloads, :both, :file, :line, keyword_init: true)

    def decls(parsed)
      out = { methods: [], consts: [], classes: [] }
      parsed.each { |file, ds| ds.each { |d| walk(d, [], file, out) } }
      out
    end

    def walk(decl, ns, file, out)
      case decl
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        name = decl.name.to_s.delete_prefix("::")
        full = name.start_with?("::") || ns.empty? ? name : "#{ns.join('::')}::#{name}"
        full = name if decl.name.absolute?
        out[:classes] << { name: full, empty: decl.members.empty?, kind: decl.is_a?(RBS::AST::Declarations::Module) ? :module : :class, file: file, line: decl.location&.start_line, ns: ns.dup }
        decl.members.each do |m|
          case m
          when RBS::AST::Members::MethodDefinition
            sep = m.kind == :singleton ? "." : "#"
            out[:methods] << Decl.new(key: "#{full}#{sep}#{m.name}", overloads: m.overloads.map(&:method_type),
                                      both: m.kind == :singleton_instance, file: file, line: m.location&.start_line)
          when RBS::AST::Declarations::Base then walk(m, full.split("::"), file, out)
          end
        end
      when RBS::AST::Declarations::Constant
        out[:consts] << { name: [*ns, decl.name.to_s].join("::"), type: decl.type, file: file, line: decl.location&.start_line }
      end
    end

    def run(config, parsed, defs)
      d = decls(parsed)
      by_key = defs.to_h { |x| [x[:key], x] }
      out = []
      names = nil
      modules = d[:classes].select { |c| c[:kind] == :module }.map { |c| c[:name] }
      d[:methods].each do |m|
        out.concat(rbs_only(m))
        out.concat(literal_return(m, by_key[m.key], names, modules))
        src = by_key[m.key] || (m.key.end_with?("#initialize") ? nil : nil)
        src ||= by_key[m.key.sub(/\.new\z/, "#initialize")] if m.key.end_with?(".new")
        next unless src

        out.concat(blocks(m, src))
        out.concat(arity(m, src))
        out.concat(nil_return(m, src))
        if !m.both && m.key.include?(".") && defs.hidden[m.key.sub(".", "#")] == "module_function"
          out << [m.key, "module_function: declare it `def self?.#{m.key.split('.').last}` (it is also a private instance method)"]
        end
      end
      d[:consts].each { |c| out.concat(const_lint(c)) }
      out.concat(privatized_mixins(config, d, parsed))
      own_src = nil
      d[:classes].each do |c|
        next unless c[:empty] && config.respond_to?(:in_ns?) && !config.in_ns?("#{c[:name]}#x")

        # A module the gem defines outside its namespace (thor's LCSDiff).
        own_src ||= Array(config.respond_to?(:lib_paths) ? config.lib_paths : []).flat_map { |dir| Dir[File.join(dir, "**/*.rb")] }
                                                                             .select { File.file?(_1) }.map { File.read(_1, encoding: "UTF-8").scrub }.join("\n")
        last = c[:name].split("::").last
        next if own_src.match?(/^\s*(class|module)\s+(::)?(\w+::)*#{Regexp.escape(last)}\b/)

        out << [c[:name], "empty declaration of a class outside the gem's namespace: if it comes from another library, load that library's RBS (manifest.yaml / _test/metadata.yaml) instead of a stub"]
      end
      out.uniq
    end

    # --- checks on the RBS alone ---

    PROTOCOL = {
      "==" => %w[bool], "!=" => %w[bool], "eql?" => %w[bool], "equal?" => %w[bool], "===" => %w[bool boolish],
      "hash" => %w[Integer], "to_s" => %w[String], "inspect" => %w[String], "to_str" => %w[String],
      "to_sym" => %w[Symbol], "to_i" => %w[Integer], "to_int" => %w[Integer], "to_a" => nil,
      "respond_to_missing?" => %w[bool], "initialize" => %w[void]
    }.freeze

    def rbs_only(m)
      out = []
      name = m.key.split(/[#.]/).last
      m.overloads.each do |mt|
        ret = mt.type.respond_to?(:return_type) ? mt.type.return_type : nil
        if (want = PROTOCOL[name]) && ret && !want.include?(ret.to_s.delete_prefix("::")) && !untyped?(ret) &&
           !(name == "initialize" && ret.is_a?(RBS::Types::Bases::Void))
          out << [m.key, "returns #{ret}; #{name} is expected to return #{want.join(' or ')}"]
        end
        if name.end_with?("?") && ret && untyped?(ret) && name != "respond_to_missing?"
          out << [m.key, "predicate returns untyped: bool (or boolish if any truthy value)"]
        end
        if ret.is_a?(RBS::Types::Tuple) && ret.types.empty?
          out << [m.key, "returns `[]`, the empty tuple: an Array is `Array[T]`"]
        end
        if (b = mt.block)
          br = b.type.respond_to?(:return_type) ? b.type.return_type : nil
          if br.is_a?(RBS::Types::Bases::Bool)
            out << [m.key, "block returns bool: callers may return any truthy value, use boolish"]
          end
        end
        if name.end_with?("=") && !%w[== != === <= >= []=].include?(name) && mt.type.is_a?(RBS::Types::Function)
          f = mt.type
          n = f.required_positionals.size + f.optional_positionals.size + f.trailing_positionals.size
          if n != 1 || f.rest_positionals || f.required_keywords.any?
            out << [m.key, "a setter takes exactly one argument (#{mt})"]
          end
        end
      end
      out
    end

    # A literal return type (`-> false`, `-> :sym`) is what `rbs prototype`
    # writes for a default body. Kept when the source has that method only
    # once in a class (a leaf's constant answer is accurate); flagged for
    # RBS-only methods and for predicates of a module that includers
    # override (ActiveModel's `persisted? -> false`). A subclass answering
    # a constant (IPv6::Mapped#mapped? -> true) is accurate.
    def literal_return(m, src, names, modules)
      name = m.key.split(/[#.]/).last
      owner = m.key.split(/[#.]/).first
      m.overloads.filter_map do |mt|
        ret = mt.type.respond_to?(:return_type) ? mt.type.return_type : nil
        next unless ret.is_a?(RBS::Types::Literal)

        pred = name.end_with?("?") && [true, false].include?(ret.literal)
        if src.nil?
          [m.key, "returns the literal type #{ret}: is that the only possible value? (`rbs prototype` writes the current value)"]
        elsif pred && modules.include?(owner) && m.key.include?("#")
          [m.key, "returns the literal #{ret}, but it is a module's instance method that includers override: bool"]
        end
      end
    end

    # `private(*FileUtils.instance_methods(false))` in a module body (Rake::DSL):
    # the module's includers get those methods as private, but an RBS
    # `include` keeps them public unless the module redeclares them under
    # `private`. Returns findings for each such module whose RBS does not.
    def privatized_mixins(config, d, parsed)
      dirs = config.respond_to?(:lib_paths) ? Array(config.lib_paths) : []
      found = []
      dirs.flat_map { |dir| Dir[File.join(dir, "**/*.rb")] }.select { File.file?(_1) }.each do |file|
        walk_private(Prism.parse_file(file).value, [], found)
      end
      return [] if found.empty?

      private_keys = {}
      parsed.each do |_, decls|
        decls.each { |dd| collect_private(dd, [], private_keys) }
      end
      found.uniq.filter_map do |mod, src_mod|
        next unless d[:classes].any? { |c| c[:name] == mod }

        declared = d[:methods].select { |x| x.key.start_with?("#{src_mod}#") || x.key.start_with?("#{src_mod.split('::').last}#") }
                              .map { |x| x.key.split("#").last }.uniq
        missing = declared.reject { |n| private_keys["#{mod}##{n}"] }
        next if missing.empty?

        [mod, "makes #{src_mod}'s methods private (private(*#{src_mod}.instance_methods)), but the RBS leaves #{missing.first(6).join(', ')}#{missing.size > 6 ? ', ...' : ''} public through include: redeclare them under `private` in #{mod}"]
      end
    end

    def walk_private(node, ns, found)
      case node
      when Prism::ModuleNode, Prism::ClassNode
        inner = ns + [node.constant_path.slice]
        node.body&.compact_child_nodes&.each { |c| walk_private(c, inner, found) }
        return
      when Prism::CallNode
        if node.receiver.nil? && node.name == :private && !ns.empty?
          (node.arguments&.arguments || []).each do |a|
            e = a.is_a?(Prism::SplatNode) ? a.expression : nil
            if e.is_a?(Prism::CallNode) && %i[instance_methods public_instance_methods].include?(e.name) && e.receiver
              found << [ns.join("::"), e.receiver.slice.delete_prefix("::")]
            end
          end
        end
      end
      node.compact_child_nodes.each { |c| walk_private(c, ns, found) }
    end

    def collect_private(decl, ns, out)
      return unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      full = (ns + [decl.name.to_s.delete_prefix("::")]).join("::")
      section = :public
      decl.members.each do |m|
        case m
        when RBS::AST::Members::Private then section = :private
        when RBS::AST::Members::Public then section = :public
        when RBS::AST::Members::MethodDefinition
          out["#{full}##{m.name}"] = true if m.kind == :instance && (m.visibility || section) == :private
        when RBS::AST::Declarations::Base then collect_private(m, full.split("::"), out)
        end
      end
    end

    def const_lint(c)
      t = c[:type]
      out = []
      if t.is_a?(RBS::Types::Literal) && t.literal.is_a?(String)
        out << [c[:name], "typed as the literal #{t}: use String (prototype runtime writes the current value)"]
      elsif t.is_a?(RBS::Types::Union) && t.types.count { |x| x.is_a?(RBS::Types::Literal) && x.literal.is_a?(String) } > 3
        out << [c[:name], "a union of #{t.types.size} string literals: String (or a type alias) reads better"]
      end
      out
    end

    def untyped?(t) = t.is_a?(RBS::Types::Bases::Any)

    def void_inside?(t)
      case t
      when RBS::Types::Union then t.types.any? { |x| x.is_a?(RBS::Types::Bases::Void) || void_inside?(x) }
      when RBS::Types::Optional then t.type.is_a?(RBS::Types::Bases::Void) || void_inside?(t.type)
      else false
      end
    end

    # --- checks against the source ---

    # Required vs optional block, a block the RBS forgets, yield arity,
    # Enumerator without a block, `[self: X]` for DSL blocks.
    def blocks(m, src)
      u = src[:block] or return []
      out = []
      with = m.overloads.select(&:block)
      without = m.overloads.reject(&:block)
      takes = !u[:yields].empty? || u[:guarded] || u[:self_eval] || u[:stored] || (u[:named] && u[:forwarded])
      if with.empty? && takes && !m.key.end_with?("#initialize")
        out << [m.key, "the source #{u[:yields].empty? ? 'takes a block (&block)' : 'yields'} but no overload declares one"]
      end
      if !with.empty? && without.empty? && with.all? { |mt| mt.block.required }
        if u[:guarded] || u[:enum]
          why = u[:enum] ? "returns an Enumerator without a block" : "checks block_given?/the block"
          out << [m.key, "the block is optional (the source #{why}): use `?{ ... }`#{u[:enum] ? ' and an overload `() -> Enumerator[...]`' : ''}"]
        end
      end
      if u[:enum] && !with.empty? && without.none? { |mt| mt.type.respond_to?(:return_type) && mt.type.return_type.to_s.include?("Enumerator") }
        out << [m.key, "without a block the source returns to_enum/enum_for: add `| (...) -> Enumerator[...]`"]
      end
      counts = u[:yields].uniq
      if counts.size == 1 && !counts.first.nil? && !with.empty?
        n = counts.first
        bad = with.select do |mt|
          f = mt.block.type
          next false unless f.is_a?(RBS::Types::Function) && f.rest_positionals.nil?

          req = f.required_positionals.size + f.trailing_positionals.size
          max = req + f.optional_positionals.size
          !(req..max).cover?(n) && !(n == 1 && req > 1) # yielding one Array to |a, b| destructures
        end
        out << [m.key, "the source yields #{n} argument#{n == 1 ? '' : 's'} but the block takes #{bad.first.block.type.param_to_s}"] unless bad.empty?
      end
      if u[:self_eval] && with.any? { |mt| mt.block.self_type.nil? }
        out << [m.key, "the block is run with instance_eval/instance_exec/...: declare `[self: X]` on it"]
      end
      out
    end

    # Positional counts and keywords against the def's parameters.
    def arity(m, src)
      ps = src[:params]
      return [] if ps.any? { |p| p[:kind] == "rest" } && ps.none? { |p| p[:kind] == "req" }

      fns = m.overloads.map(&:type).grep(RBS::Types::Function)
      return [] if fns.empty?

      out = []
      req = ps.count { |p| p[:kind] == "req" }
      opt = ps.count { |p| p[:kind] == "opt" }
      rest = ps.any? { |p| p[:kind] == "rest" }
      # Per block form: thor's create_file(dest, *args) needed data in every
      # blockless overload, though `args.first` makes it optional.
      need = ->(f) { f.required_positionals.size + f.trailing_positionals.size }
      groups = m.overloads.select { |mt| mt.type.is_a?(RBS::Types::Function) }.group_by { |mt| !mt.block.nil? }
      # *args counts as optional only where the source gives the missing
      # value a default (`data = args.first ... data.to_s`, `args.first || x`);
      # `data = args.shift` passed on as nil is still required.
      rest_default = rest && rest_default?(src, ps.find { |p| p[:kind] == "rest" }[:name])
      # A default may be an alternative to the block (`def builds(proc = nil,
      # &block)`): those are judged over all overloads. Per block form only
      # for *args with a default.
      groups = { nil => groups.values.flatten } unless rest_default
      if opt.positive? || rest_default
        groups.each do |with_block, mts|
          min = mts.map { |mt| need.(mt.type) }.min
          next unless min > req

          form = groups.size > 1 && !with_block.nil? ? (with_block ? "with a block, every overload" : "without a block, every overload") : "every overload"
          why = opt.positive? ? "the others have defaults" : "the value read from *args gets a default"
          out << [m.key, "#{form} requires #{min} positional argument#{min == 1 ? '' : 's'} but the source requires #{req} (#{why}): add `?` or an overload"]
        end
      end
      unless rest || fns.any?(&:rest_positionals)
        max = fns.map { |f| f.required_positionals.size + f.optional_positionals.size + f.trailing_positionals.size }.max
        out << [m.key, "the source requires #{req} positional arguments but no overload takes more than #{max}"] if max < req
      end
      keyrest = ps.any? { |p| p[:kind] == "keyrest" }
      unless fns.any?(&:rest_keywords)
        declared = fns.flat_map { |f| f.required_keywords.keys + f.optional_keywords.keys }.map(&:to_s)
        missing = ps.select { |p| %w[keyreq].include?(p[:kind]) && !declared.include?(p[:name]) }
        missing.each { |p| out << [m.key, "required keyword `#{p[:name]}:` is not declared"] } if declared.any? || !keyrest
        optional = ps.select { |p| p[:kind] == "key" && !declared.include?(p[:name]) }
        if !optional.empty? && declared.any?
          out << [m.key, "keyword#{optional.size == 1 ? '' : 's'} #{optional.map { "`#{_1[:name]}:`" }.join(', ')} not declared (callers passing #{optional.size == 1 ? 'it' : 'them'} are rejected)"]
        end
      end
      out
    end

    def rest_default?(src, name)
      return false unless src[:file] && File.file?(src[:file])

      body = File.readlines(src[:file], encoding: "UTF-8")[(src[:line] - 1)...src[:end_line]].join
      n = Regexp.escape(name)
      # The first value read from *args (the first missing positional);
      # later reads (`config = args.shift || {}`) are other parameters.
      line = body.lines.find { |l| l.match?(/\b#{n}(?:\.first|\.shift|\[0\])/) } or return false
      return true if line.match?(/\b#{n}(?:\.first|\.shift|\[0\])\s*(?:\|\||\.to_s\b|\.to_a\b|\.to_sym\b)/)

      var = line[/(\w+)\s*=\s*(?:[^=\n]*\?[^:\n]*:\s*)?#{n}(?:\.first|\.shift|\[0\])/, 1] or return false
      body.match?(/\b#{Regexp.escape(var)}(?:\.to_s\b|\.to_a\b|\s*\|\|(?!=))/)
    end

    # A body that can end in nil (`return`, `if` without else, a `nil`
    # literal) with a return type that cannot be nil.
    def nil_return(m, src)
      return [] if m.key.end_with?("#initialize", ".new") || m.key.end_with?("=")

      can_nil = src[:implicit_nil] || src[:fixed_returns].include?("nil") || src[:early_nil]
      return [] unless can_nil

      rets = m.overloads.map { |mt| mt.type.respond_to?(:return_type) ? mt.type.return_type : nil }.compact
      return [] if rets.empty? || rets.any? { |r| nilable?(r) }

      how = src[:fixed_returns].include?("nil") || src[:early_nil] ? "returns nil" : "can end without a value (bare `return`, `if`/`case` without `else`, empty body; ignore if the branches are exhaustive)"
      [[m.key, "the source #{how} but the return type #{rets.uniq.map(&:to_s).join(' / ')} excludes nil"]]
    end

    def nilable?(t)
      case t
      when RBS::Types::Optional, RBS::Types::Bases::Nil, RBS::Types::Bases::Any, RBS::Types::Bases::Void,
           RBS::Types::Bases::Bottom, RBS::Types::Bases::Top, RBS::Types::Bases::Bool, RBS::Types::Variable
        true
      when RBS::Types::Union then t.types.any? { |x| nilable?(x) }
      when RBS::Types::Alias, RBS::Types::Interface then true # cannot tell
      when RBS::Types::ClassInstance then %w[boolish ::boolish].include?(t.name.to_s)
      else false
      end
    end

    # --- the gem directory: test style, manifest ---

    # Constants of stdlib libraries that need a manifest.yaml entry (or a
    # gemspec dependency of the same name) when the RBS refers to them.
    STDLIB = {
      "URI" => "uri", "Date" => "date", "DateTime" => "date", "IPAddr" => "ipaddr", "Logger" => "logger",
      "Pathname" => "pathname", "StringIO" => "stringio", "Monitor" => "monitor", "MonitorMixin" => "monitor",
      "Forwardable" => "forwardable", "Tempfile" => "tempfile", "OpenSSL" => "openssl", "Net" => "net-http",
      "Singleton" => "singleton", "CGI" => "cgi", "ERB" => "erb", "JSON" => "json", "Psych" => "psych",
      "YAML" => "yaml", "Digest" => "digest", "SecureRandom" => "securerandom", "Socket" => "socket",
      "TCPSocket" => "socket", "Timeout" => "timeout", "Zlib" => "zlib", "OpenStruct" => "ostruct",
      "Shellwords" => "shellwords", "Open3" => "open3", "Etc" => "etc", "Benchmark" => "benchmark",
      "BigDecimal" => "bigdecimal", "Find" => "find", "FileUtils" => "fileutils", "OptionParser" => "optparse",
      "PP" => "pp", "Prime" => "prime", "Ripper" => "ripper", "TSort" => "tsort", "Coverage" => "coverage",
      "Resolv" => "resolv", "PStore" => "pstore", "Abbrev" => "abbrev", "Base64" => "base64", "DRb" => "drb",
      "Observable" => "observer", "WeakRef" => "weakref", "Readline" => "readline", "IO::Console" => "io-console"
    }.freeze

    def layout(sigdir, gem_deps: [], text: nil)
      out = []
      test = File.join(sigdir, "_test", "test.rb")
      if File.exist?(test)
        t = File.read(test, encoding: "UTF-8")
        calls = t.lines.count { |l| l =~ /\w[.]\w/ && l !~ /\A\s*#/ }
        types = t.scan(/^\s*# @type var /).size
        if types.zero?
          out << ["_test/test.rb", "no `# @type var x: T` assertions: the collection's tests pin return types with them (89% of recently added gems)"]
        elsif calls > types * 5
          out << ["_test/test.rb", "#{types} `# @type var` assertions for ~#{calls} calls: assert the return types of the main calls"]
        end
        if t.include?("Write Ruby code to test the RBS")
          out << ["_test/test.rb", "still has bin/init_new_gem's header comment: remove it"]
        end
      else
        out << ["_test/test.rb", "missing: bin/test only warns, but reviewers expect a test"]
      end
      # bin/test writes these next to the test (they are gitignored).
      tracked = Dir.chdir(sigdir) { `git ls-files -- _test 2>/dev/null`.split("\n") }
      %w[Steepfile rbs_collection.yaml rbs_collection.lock.yaml].each do |f|
        out << ["_test/#{f}", "must not be committed (bin/test generates it)"] if tracked.include?("_test/#{f}")
      end
      # CI's strict_rubocop_config.rb: only inherit_from and RBS* cops, and
      # a restricted character set (RuboCop config can run code).
      rubocop = File.join(File.dirname(sigdir), ".rubocop.yml")
      if File.exist?(rubocop)
        rc = File.read(rubocop)
        out << [".rubocop.yml", "characters outside [a-zA-Z0-9 _/#:'\".,-*]: CI rejects it"] if rc.match?(%r{[^a-zA-Z0-9\s_/#:'".,\-*]})
        keys = (YAML.safe_load(rc) || {}).keys rescue []
        bad = keys.reject { |k| k == "inherit_from" || k.start_with?("RBS") }
        out << [".rubocop.yml", "only inherit_from and RBS* keys are allowed (#{bad.join(', ')})"] unless bad.empty?
      else
        out << [".rubocop.yml", "missing: copy it from bin/init_new_gem's template"]
      end
      manifest = File.join(sigdir, "manifest.yaml")
      listed = []
      if File.exist?(manifest)
        y = YAML.safe_load_file(manifest) || {}
        Array(y["dependencies"]).each do |e|
          unless e.is_a?(Hash) && e["name"].is_a?(String)
            out << ["manifest.yaml", "entry #{e.inspect} must be `- name: <library>`"]
            next
          end
          listed << e["name"]
          out << ["manifest.yaml", "#{e['name']} is not a library in rbs's stdlib (gem dependencies come from the gemspec, not the manifest)"] unless stdlib?(e["name"])
          out << ["manifest.yaml", "#{e['name']} is already a gemspec dependency: rbs collection loads it without the manifest"] if gem_deps.include?(e["name"])
        end
      end
      text ||= RbsReader.sig_files(sigdir).map { |f| File.read(f, encoding: "UTF-8") }.join("\n")
      body = text.gsub(/#.*$/, "")
      used = STDLIB.select { |const, _| body.match?(/(?<![\w:])(::)?#{Regexp.escape(const)}(::|\b)(?!\s*[:=])/) }.values.uniq
      own = text.scan(/^\s*(?:class|module)\s+(?:::)?([A-Z]\w*)/).flatten
      used.reject! { |lib| STDLIB.select { |_, l| l == lib }.keys.all? { |c| own.include?(c.split("::").first) } }
      (used - listed - gem_deps).each do |lib|
        out << ["manifest.yaml", "the RBS uses #{STDLIB.key(lib)} (#{lib}): add `- name: #{lib}` unless a dependency's RBS already loads it"]
      end
      out
    end

    def stdlib?(name)
      File.directory?(File.join(RBS::Repository::DEFAULT_STDLIB_ROOT, name))
    end

    # Share of declaration lines mentioning untyped (the recently added
    # gems' median is 0.22, p75 0.35).
    def untyped_density(text)
      lines = text.lines.grep(/^\s*(def |attr_|[A-Z]\w*: |type )/)
      return 0.0 if lines.empty?

      (lines.count { |l| l.include?("untyped") }.to_f / lines.size).round(2)
    end
  end
end
