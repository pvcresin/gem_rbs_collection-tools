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
  # conventions. Every finding is a Finding ([key, message] plus an optional
  # mechanical fix); none needs the gem loaded. `lint --fix` applies the
  # fixes (apply_fixes): text spliced at the RBS AST's locations, so the
  # formatting and comments around them stay as they are.
  module Lint
    # One text change: replace `range` (character offsets) of `file` with
    # `replacement`; an empty range inserts.
    Edit = Struct.new(:file, :range, :replacement, keyword_init: true)

    # Still the Array [key, message] for callers (`|key, msg|`, uniq);
    # `fix` holds the edits that resolve it where they are safe and
    # unambiguous, nil where it needs a human.
    class Finding < Array
      attr_reader :fix

      def initialize(key, message, fix = nil)
        super([key, message])
        @fix = fix.nil? || fix.empty? ? nil : fix
      end

      def key = self[0]
      def message = self[1]
    end

    module_function

    def finding(key, message, fix = nil) = Finding.new(key, message, fix)
    def edit_at(file, loc, text) = Edit.new(file: file, range: loc.start_pos...loc.end_pos, replacement: text)
    def insert_at(file, pos, text) = Edit.new(file: file, range: pos...pos, replacement: text)

    # One method declaration: key "A::B#m" / "A::B.m", its overloads
    # (RBS::MethodType), whether it is `def self?.`, and the
    # RBS::AST::Members::MethodDefinition (for its locations) and the name
    # resolution context of its declaration.
    Decl = Struct.new(:key, :overloads, :both, :file, :line, :member, :ctx, keyword_init: true)

    def decls(parsed)
      out = { methods: [], consts: [], classes: [] }
      parsed.each { |file, ds| ds.each { |d| walk(d, [], file, out) } }
      out
    end

    def walk(decl, ns, file, out, ctx = nil)
      case decl
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        name = decl.name.to_s.delete_prefix("::")
        full = name.start_with?("::") || ns.empty? ? name : "#{ns.join('::')}::#{name}"
        full = name if decl.name.absolute?
        # RBS's resolution context: [outer context, absolute name].
        ctx = [ctx, RBS::TypeName.parse("::#{full}")]
        sup = decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class ? decl.super_class.name.to_s.delete_prefix("::") : nil
        out[:classes] << { name: full, super: sup, empty: decl.members.empty?, kind: decl.is_a?(RBS::AST::Declarations::Module) ? :module : :class, file: file, line: decl.location&.start_line, ns: ns.dup, decl: decl, ctx: ctx }
        decl.members.each do |m|
          case m
          when RBS::AST::Members::MethodDefinition
            sep = m.kind == :singleton ? "." : "#"
            out[:methods] << Decl.new(key: "#{full}#{sep}#{m.name}", overloads: m.overloads.map(&:method_type),
                                      both: m.kind == :singleton_instance, file: file, line: m.location&.start_line, member: m, ctx: ctx)
          when RBS::AST::Declarations::Base then walk(m, full.split("::"), file, out, ctx)
          end
        end
      when RBS::AST::Declarations::Constant
        out[:consts] << { name: [*ns, decl.name.to_s].join("::"), type: decl.type, file: file, line: decl.location&.start_line, decl: decl }
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
        out.concat(super_block(m, src, d))
        out.concat(arity(m, src))
        out.concat(nil_return(m, src))
        if !m.both && m.key.include?(".") && defs.hidden[m.key.sub(".", "#")] == "module_function"
          out << finding(m.key, "module_function: declare it `def self?.#{m.key.split('.').last}` (it is also a private instance method)",
                         module_function_fix(m, d))
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
      merge(out)
    end

    # uniq, keeping the edits of every copy (one finding per overload
    # becomes one finding whose fix covers all of them).
    def merge(out)
      seen = {}
      out.each do |f|
        k = [f[0], f[1]]
        prev = seen[k]
        if prev.nil?
          seen[k] = f
        elsif f.respond_to?(:fix) && f.fix
          seen[k] = Finding.new(k[0], k[1], (prev.respond_to?(:fix) && prev.fix || []) + f.fix)
        end
      end
      seen.values
    end

    def module_function_fix(m, d)
      kind = m.member&.location&.[](:kind) or return nil
      return nil unless kind.source == "self."

      owner, name = m.key.split(".", 2)
      # An instance declaration of the same name would become a duplicate.
      return nil if d[:methods].any? { |x| x.key == "#{owner}##{name}" }

      [edit_at(m.file, kind, "self?.")]
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
            out << finding(m.key, "block returns bool: callers may return any truthy value, use boolish",
                           br.location ? [edit_at(m.file, br.location, "boolish")] : nil)
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
          finding(m.key, "returns the literal #{ret}, but it is a module's instance method that includers override: bool",
                  ret.location ? [edit_at(m.file, ret.location, "bool")] : nil)
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

        src_decls = d[:methods].select { |x| x.key.start_with?("#{src_mod}#") || x.key.start_with?("#{src_mod.split('::').last}#") }
        declared = src_decls.map { |x| x.key.split("#").last }.uniq
        missing = declared.reject { |n| private_keys["#{mod}##{n}"] }
        next if missing.empty?

        finding(mod, "makes #{src_mod}'s methods private (private(*#{src_mod}.instance_methods)), but the RBS leaves #{missing.first(6).join(', ')}#{missing.size > 6 ? ', ...' : ''} public through include: redeclare them under `private` in #{mod}",
                privatized_fix(mod, src_mod, missing, src_decls, d))
      end
    end

    # Methods the module already declares publicly get `private ` in front
    # of their own declaration; the others are copied from the included
    # module's declarations and inserted before the module's `end` under
    # `private` (a new `private` line unless the body already ends in a
    # private section). The module chosen is the declaration that includes
    # src_mod.
    def privatized_fix(mod, src_mod, missing, src_decls, d)
      cands = d[:classes].select { |c| c[:name] == mod && c[:decl] }
      own = {}
      cands.each do |cc|
        section = :public
        cc[:decl].members.each do |m|
          section = :private if m.is_a?(RBS::AST::Members::Private)
          section = :public if m.is_a?(RBS::AST::Members::Public)
          next unless m.is_a?(RBS::AST::Members::MethodDefinition) && m.kind == :instance && missing.include?(m.name.to_s)

          (own[m.name.to_s] ||= []) << [cc, m, section]
        end
      end
      edits = []
      own.each_value do |list|
        list.each do |cc, m, section|
          # `public def x` or an annotated declaration: leave it to a human.
          return nil if m.visibility || !m.annotations.empty? || m.location.nil?

          edits << insert_at(cc[:file], m.location.start_pos, "private ") if section == :public
        end
      end
      copy = missing - own.keys
      return edits if copy.empty?

      c = cands.find { |x| x[:decl].members.any? { |m| m.is_a?(RBS::AST::Members::Include) && m.name.to_s.delete_prefix("::").end_with?(src_mod.split("::").last) } } || cands.first
      return nil unless c

      decl = c[:decl]
      end_loc = decl.location&.[](:end) or return nil
      content = end_loc.buffer.content
      line_start = (content.rindex("\n", end_loc.start_pos - 1) || -1) + 1
      return nil unless content[line_start...end_loc.start_pos].strip.empty? # `end` on a line of its own

      indent = " " * (decl.location.start_column + 2)
      resolver = type_resolver(d, src_mod) or return nil
      copies = copy.filter_map do |n|
        x = src_decls.find { |s| s.key.split("#").last == n } or next
        loc = x.member&.location or next
        text = requalify(x, c[:ctx], resolver) or next
        reindent(text, loc.start_column, indent.size)
      end
      return nil if copies.size != copy.size

      section = :public
      decl.members.each do |m|
        section = :private if m.is_a?(RBS::AST::Members::Private)
        section = :public if m.is_a?(RBS::AST::Members::Public)
      end
      head = section == :private && !decl.members.empty? ? "" : "\n#{indent}private\n\n"
      edits << insert_at(c[:file], line_start, head + copies.map { "#{indent}#{_1}\n" }.join)
    end

    # Resolves type names against core, the stdlib libraries of the
    # manifest and of src_mod, and the RBS being linted. nil when it cannot
    # be built.
    def type_resolver(d, src_mod)
      loader = RBS::EnvironmentLoader.new
      files = d[:classes].map { |c| c[:file] }.uniq
      libs = [STDLIB[src_mod]]
      files.map { |f| File.join(File.dirname(f), "manifest.yaml") }.uniq.select { File.file?(_1) }.each do |m|
        Array((YAML.safe_load_file(m) || {})["dependencies"]).each { |e| libs << e["name"] if e.is_a?(Hash) }
      end
      libs.compact.uniq.select { |l| stdlib?(l) }.each { |l| loader.add(library: l, version: nil) }
      env = RBS::Environment.from_loader(loader)
      files.each do |f|
        buf = RBS::Buffer.new(name: f, content: File.read(f, encoding: "UTF-8"))
        _, dirs, decls = RBS::Parser.parse_signature(buf)
        env.add_source(RBS::Source::RBS.new(buf, dirs, decls))
      end
      RBS::Resolver::TypeNameResolver.build(env)
    rescue StandardError
      nil
    end

    # The source of declaration x with each relative type name that would
    # resolve differently in `ctx` written as the absolute name it has
    # where x is declared (`pathlist` in FileUtils -> `::FileUtils::pathlist`).
    # nil when a name does not resolve at all.
    def requalify(x, ctx, resolver)
      loc = x.member.location
      edits = []
      ok = true
      visit = lambda do |t|
        if t.respond_to?(:name) && t.name.is_a?(RBS::TypeName) && !t.name.absolute? && t.location && t.location[:name]
          from = resolver.resolve(t.name, context: x.ctx)
          if from.nil?
            ok = false
          elsif resolver.resolve(t.name, context: ctx) != from
            n = t.location[:name]
            edits << [n.start_pos - loc.start_pos, n.end_pos - loc.start_pos, from.to_s]
          end
        end
        t.each_type { |c| visit.(c) } if t.respond_to?(:each_type)
      end
      x.member.overloads.each do |o|
        mt = o.method_type
        mt.type.each_type { |c| visit.(c) } if mt.type.respond_to?(:each_type)
        if mt.block
          mt.block.type.each_type { |c| visit.(c) } if mt.block.type.respond_to?(:each_type)
          visit.(mt.block.self_type) if mt.block.self_type
        end
      end
      return nil unless ok

      src = loc.source
      edits.sort_by(&:first).reverse_each { |b, e, r| src = src[0...b] + r + src[e..] }
      src
    end

    # A declaration's source moved from column `from` to `to`: the first
    # line is placed by the caller, continuation lines shift with it.
    def reindent(src, from, to)
      first, *rest = src.lines
      shift = to - from
      rest = rest.map { |l| shift >= 0 ? (" " * shift) + l : l.sub(/\A {0,#{-shift}}/, "") }
      ([first] + rest).join.chomp
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
        out << finding(c[:name], "typed as the literal #{t}: use String (prototype runtime writes the current value)",
                       t.location ? [edit_at(c[:file], t.location, "String")] : nil)
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
      if with.empty? && takes
        out << [m.key, "the source #{u[:yields].empty? ? 'takes a block (&block)' : 'yields'} but no overload declares one"]
      end
      if !with.empty? && without.empty? && with.all? { |mt| mt.block.required }
        if (u[:guarded] || u[:enum]) && !u[:requires]
          why = u[:enum] ? "returns an Enumerator without a block" : "checks block_given?/the block"
          # An Enumerator overload makes the block optional by itself (with
          # `?{` the blockless call would match the first overload).
          fix = if u[:enum]
                  enum_overload_fix(m, with)
                elsif !guard_returns_value?(src)
                  with.filter_map { |mt| mt.block.location && insert_at(m.file, mt.block.location.start_pos, "?") }
                end
          out << finding(m.key, "the block is optional (the source #{why}): use `?{ ... }`#{u[:enum] ? ' and an overload `() -> Enumerator[...]`' : ''}", fix)
        end
      end
      if u[:enum] && !with.empty? && without.none? { |mt| mt.type.respond_to?(:return_type) && mt.type.return_type.to_s.include?("Enumerator") }
        out << finding(m.key, "without a block the source returns to_enum/enum_for: add `| (...) -> Enumerator[...]`", enum_overload_fix(m, with))
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

    # Whether the blockless path returns its own value (`return @keys.reject!
    # unless block`): then `?{` would give it the block form's return type,
    # so the fix is left to a human.
    def guard_returns_value?(src)
      return true unless src[:file] && File.file?(src[:file])

      defn = def_node_at(src[:file], src[:line]) or return true
      blk = defn.parameters&.block&.name
      mentions = lambda do |n|
        next false if n.nil?
        next true if n.is_a?(Prism::CallNode) && n.receiver.nil? && %i[block_given? iterator?].include?(n.name)
        next true if blk && n.is_a?(Prism::LocalVariableReadNode) && n.name == blk

        n.compact_child_nodes.any? { |c| mentions.(c) }
      end
      returns = lambda do |n|
        next false if n.nil? || n.is_a?(Prism::DefNode)
        if n.is_a?(Prism::ReturnNode)
          args = n.arguments&.arguments || []
          next true unless args.empty? || (args.size == 1 && args.first.is_a?(Prism::NilNode))
        end
        n.compact_child_nodes.any? { |c| returns.(c) }
      end
      stack = [defn.body].compact
      while (n = stack.pop)
        next if n.is_a?(Prism::DefNode)

        case n
        when Prism::IfNode, Prism::UnlessNode
          return true if mentions.(n.predicate) && returns.(n)
        when Prism::AndNode, Prism::OrNode
          return true if mentions.(n.left) && returns.(n.right)
        end
        stack.concat(n.compact_child_nodes)
      end
      false
    end

    def def_node_at(file, line)
      @def_nodes ||= {}
      root = (@def_nodes[[file, File.mtime(file)]] ||= Prism.parse_file(file).value)
      stack = [root]
      while (n = stack.pop)
        return n if n.is_a?(Prism::DefNode) && n.location.start_line == line

        stack.concat(n.compact_child_nodes)
      end
      nil
    end

    # `| (<params>) -> Enumerator[<block param>, <return type>]` after the
    # last overload: only for one overload with a required block, no type
    # parameters and no `...`.
    def enum_overload_fix(m, with)
      return nil unless with.size == 1 && m.member && !m.member.overloading? && with.first.block.required

      mt = with.first
      f = mt.type
      return nil unless f.is_a?(RBS::Types::Function) && mt.type_params.empty?

      b = mt.block.type
      elem = if b.is_a?(RBS::Types::Function) && b.optional_positionals.empty? && b.rest_positionals.nil? && b.trailing_positionals.empty?
               ts = b.required_positionals.map { |p| p.type.to_s }
               ts.size == 1 ? ts.first : ts.empty? ? "untyped" : "[#{ts.join(', ')}]"
             else
               "untyped"
             end
      elem = "untyped" if elem == "void"
      ret = f.return_type.is_a?(RBS::Types::Bases::Void) ? "untyped" : f.return_type.to_s
      last = m.member.overloads.last.method_type.location or return nil
      col = overload_column(m) or return nil
      [insert_at(m.file, last.end_pos, "\n#{' ' * col}| (#{f.param_to_s}) -> Enumerator[#{elem}, #{ret}]")]
    end

    # The column of `|` for a new overload: under the existing `|`, else
    # under the `:` after the method name.
    def overload_column(m)
      content = m.member.location.buffer.content
      pos = if m.member.overloads.size > 1
              second = m.member.overloads[1].method_type.location or return nil
              content.rindex("|", second.start_pos)
            else
              name = m.member.location[:name] or return nil
              content.index(":", name.end_pos)
            end
      return nil unless pos

      pos - ((content.rindex("\n", pos) || -1) + 1)
    end

    # `super` / `super(args)` passes the caller's block on. When the RBS of
    # the superclass's method takes a block and this one declares none,
    # `Sub.new { ... }` is rejected although it works (highline's
    # SampleColorScheme#initialize calls super(SAMPLE_SCHEME)).
    def super_block(m, src, d)
      u = src[:block] or return []
      return [] unless u[:super] && m.overloads.none?(&:block)

      owner, sep, name = m.key.rpartition(/[#.]/)
      return [] unless sep == "#"

      by_name = d[:classes].to_h { |c| [c[:name], c] }
      seen = []
      cls = by_name[owner]
      while cls && (sup = cls[:super]) && !seen.include?(sup)
        seen << sup
        cand = [sup, *owner.split("::")[0..-2].each_index.map { |i| (owner.split("::")[0..i] + [sup]).join("::") }]
        target = cand.find { |n| by_name.key?(n) } or break
        decl = d[:methods].find { |x| x.key == "#{target}##{name}" }
        if decl&.overloads&.any?(&:block)
          blk = decl.overloads.find(&:block).block
          return [[m.key, "super passes the block on to #{target}##{name}, which takes one: declare `?{ #{blk.type.param_to_s.empty? ? '()' : "(#{blk.type.param_to_s})"} ... }` here too"]]
        end
        cls = by_name[target]
      end
      []
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
          out << finding(m.key, "#{form} requires #{min} positional argument#{min == 1 ? '' : 's'} but the source requires #{req} (#{why}): add `?` or an overload",
                         arity_fix(m, mts, ps, req, opt, rest))
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

    # `?` on the positionals past the source's required count, in each
    # overload of the group that requires them, skipping an overload whose
    # new argument counts another overload of the same block form already
    # accepts (an ambiguous overload). For *args with a
    # default only the first value read gets one: only an overload with
    # exactly one positional too many is changed. Not with post-required
    # parameters (`def m(a, b = 1, c)`), where the mapping is unclear.
    def arity_fix(m, mts, ps, req, opt, rest)
      return nil if m.member.nil? || m.member.overloading?

      kinds = ps.map { |p| p[:kind] }.select { |k| %w[req opt rest].include?(k) }
      return nil if kinds.each_cons(2).any? { |a, b| a != "req" && b == "req" }

      all = m.member.overloads.map(&:method_type)
      ranges = all.map { |mt| arity_range(mt) }
      edits = []
      mts.each do |mt|
        f = mt.type
        next unless f.is_a?(RBS::Types::Function) && f.trailing_positionals.empty?

        n = f.required_positionals.size
        next unless n > req
        next if opt.positive? ? (!rest && n > req + opt) : n != req + 1

        targets = f.required_positionals[req..]
        next if targets.any? { |p| p.location.nil? }

        i = all.index { |x| x.equal?(mt) } or next
        # The argument counts it newly accepts must not be accepted by
        # another overload of the same block form.
        added = [req, ranges[i][0] - 1]
        next if all.each_index.any? { |j| j != i && same_form?(all[i], all[j]) && overlap?(added, ranges[j]) }

        trial = ranges.dup
        trial[i] = [req, ranges[i][1]]

        ranges = trial
        edits.concat(targets.map { |p| insert_at(m.file, p.location.start_pos, "?") })
      end
      edits
    end

    def arity_range(mt)
      f = mt.type
      return [0, Float::INFINITY] unless f.is_a?(RBS::Types::Function)

      need = f.required_positionals.size + f.trailing_positionals.size
      [need, f.rest_positionals ? Float::INFINITY : need + f.optional_positionals.size]
    end

    def overlap?(a, b) = a[0] <= b[1] && b[0] <= a[1]

    # Both accept a call without a block, or both one with a block.
    def same_form?(a, b)
      without = ->(mt) { mt.block.nil? || !mt.block.required }
      (without.(a) && without.(b)) || (a.block && b.block)
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

      explicit = src[:fixed_returns].include?("nil") || src[:early_nil]
      how = explicit ? "returns nil" : "can end without a value (bare `return`, `if`/`case` without `else`, empty body; ignore if the branches are exhaustive)"
      # Fixed only for an explicit nil (`return nil`, a nil literal, bare
      # `return`) and a single overload: an implicit nil may be an
      # exhaustive if/case, and with several overloads the nil may belong
      # to one of them.
      fix = explicit && rets.size == 1 && m.overloads.size == 1 ? optional_fix(m.file, rets.first) : nil
      [finding(m.key, "the source #{how} but the return type #{rets.uniq.map(&:to_s).join(' / ')} excludes nil", fix)]
    end

    # T -> T?, with parentheses around a union, intersection or proc.
    def optional_fix(file, t)
      loc = t.location or return nil
      src = loc.source
      wrap = t.is_a?(RBS::Types::Union) || t.is_a?(RBS::Types::Intersection) || t.is_a?(RBS::Types::Proc)
      return [edit_at(file, loc, "#{src}?")] unless wrap

      # `-> (A | B)`: the location is inside the parentheses; take them in.
      content = loc.buffer.content
      b = loc.start_pos
      e = loc.end_pos
      b -= 1 while b.positive? && content[b - 1].match?(/[ \t]/)
      e += 1 while content[e]&.match?(/[ \t]/)
      if b.positive? && content[b - 1] == "(" && content[e] == ")"
        return [Edit.new(file: file, range: (b - 1)...(e + 1), replacement: "(#{src})?")]
      end
      [edit_at(file, loc, "(#{src})?")]
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
        if rc.match?(/^\s*Exclude:/)
          out << [".rubocop.yml", "has Exclude entries: autocorrect the old version directory (rubocop -a) instead of excluding it"]
        end
      else
        out << [".rubocop.yml", "missing: copy it from bin/init_new_gem's template"]
      end
      manifest = File.join(sigdir, "manifest.yaml")
      listed = []
      bare = []
      mtext = File.exist?(manifest) ? File.read(manifest, encoding: "UTF-8") : nil
      if mtext
        y = YAML.safe_load(mtext) || {}
        Array(y["dependencies"]).each do |e|
          unless e.is_a?(Hash) && e["name"].is_a?(String)
            bare << e if e.is_a?(String)
            out << finding("manifest.yaml", "entry #{e.inspect} must be `- name: <library>`", manifest_entry_fix(manifest, mtext, e))
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
      add = used - listed - gem_deps
      # A bare `- monitor` is fixed in place, not added again.
      adding = add - bare
      add.each do |lib|
        fix = adding.include?(lib) ? manifest_add_fix(manifest, mtext, lib, first: lib == adding.first) : nil
        out << finding("manifest.yaml", "the RBS uses #{STDLIB.key(lib)} (#{lib}): add `- name: #{lib}` unless a dependency's RBS already loads it", fix)
      end
      out
    end

    # `- monitor` -> `- name: monitor`, when exactly one line holds it.
    def manifest_entry_fix(path, text, entry)
      return nil unless entry.is_a?(String) && entry.match?(/\A[\w.-]+\z/)

      re = /^([ \t]*)-[ \t]+(["']?)#{Regexp.escape(entry)}\2[ \t]*(#.*)?$/
      hits = []
      text.scan(re) { hits << Regexp.last_match }
      return nil unless hits.size == 1

      h = hits.first
      comment = h[3] ? " #{h[3]}" : ""
      [Edit.new(file: path, range: h.begin(0)...h.end(0), replacement: "#{h[1]}- name: #{entry}#{comment}")]
    end

    # `- name: lib` appended to the dependencies list (the list, or the
    # file, created by the first library added). Several additions insert
    # at the same place and keep their order.
    def manifest_add_fix(path, text, lib, first:)
      if text.nil?
        return [insert_at(path, 0, "#{first ? "dependencies:\n" : ''}  - name: #{lib}\n")]
      end

      lines = text.lines
      head = lines.index { |l| l.match?(/\Adependencies:[ \t]*(#.*)?\n?\z/) }
      if head.nil?
        return nil if text.match?(/^dependencies:/) # an inline value (`dependencies: []`)

        pre = first && !text.empty? && !text.end_with?("\n") ? "\n" : ""
        return [insert_at(path, text.length, "#{pre}#{first ? "dependencies:\n" : ''}  - name: #{lib}\n")]
      end

      last = head
      indent = nil
      ((head + 1)...lines.size).each do |i|
        l = lines[i]
        next if l.strip.empty? || l.match?(/\A\s*#/)
        break unless l.match?(/\A[ \t]*-/) || l.match?(/\A[ \t]+\S/)

        indent ||= l[/\A([ \t]*)-/, 1]
        last = i
      end
      pos = lines[0..last].sum(&:length)
      pre = first && !lines[last].end_with?("\n") ? "\n" : ""
      [insert_at(path, pos, "#{pre}#{indent || '  '}- name: #{lib}\n")]
    end

    def stdlib?(name)
      File.directory?(File.join(RBS::Repository::DEFAULT_STDLIB_ROOT, name))
    end

    # --- --fix ---

    # Applies the fixes of `findings` to their files. Per file: identical
    # edits from several findings count once, a finding whose edits overlap
    # an earlier finding's is skipped, and the result must still parse
    # (RBS, or YAML for the manifest) or the file is left unchanged.
    # Returns { applied: [[finding, [description, ...]]], failed: [[finding, reason]] }.
    def apply_fixes(findings)
      res = { applied: [], failed: [] }
      by_file = {}
      findings.each do |f|
        next unless f.respond_to?(:fix) && f.fix

        f.fix.group_by(&:file).each { |file, es| (by_file[file] ||= []) << [f, es] }
      end
      by_file.each do |file, items|
        text = File.exist?(file) ? File.read(file, encoding: "UTF-8") : ""
        taken = []
        accepted = []
        items.each do |f, es|
          es = es.uniq { |e| [e.range, e.replacement] }.reject { |e| taken.any? { |t| t.range == e.range && t.replacement == e.replacement } }
          if es.any? { |e| taken.any? { |t| edits_overlap?(t.range, e.range) } }
            res[:failed] << [f, "its edit overlaps another fix"]
            next
          end
          taken.concat(es)
          accepted << [f, es]
        end
        new_text = splice(text, taken)
        if (err = parse_error(file, new_text))
          accepted.each { |f, _| res[:failed] << [f, "#{File.basename(file)} would not parse after the fixes (#{err}); left unchanged"] }
          next
        end
        File.write(file, new_text) unless new_text == text
        accepted.each { |f, es| res[:applied] << [f, es.empty? ? ["(the same edit as above)"] : es.map { |e| describe_edit(text, e) }] }
      end
      res
    end

    def edits_overlap?(a, b) = a.begin < b.end && b.begin < a.end

    # Edits in position order; insertions at one place keep their order.
    def splice(text, edits)
      out = +""
      cur = 0
      edits.each_with_index.sort_by { |e, i| [e.range.begin, i] }.each do |e, _|
        out << text[cur...e.range.begin] << e.replacement
        cur = e.range.end
      end
      out << text[cur..].to_s
    end

    def parse_error(file, text)
      case File.extname(file)
      when ".rbs"
        RBS::Parser.parse_signature(RBS::Buffer.new(name: file, content: text))
      when ".yaml", ".yml"
        y = YAML.safe_load(text)
        return "dependencies is not a list" if y.is_a?(Hash) && !y["dependencies"].nil? && !y["dependencies"].is_a?(Array)
      end
      nil
    rescue RBS::BaseError, Psych::Exception => e
      e.message.lines.first.to_s.strip
    end

    def describe_edit(text, e)
      line = text[0...e.range.begin].count("\n") + 1
      old = text[e.range]
      where = "#{File.basename(e.file)}:#{line}"
      if old.empty?
        new = e.replacement.sub(/\A\n+/, "").rstrip
        lines = new.lines.map(&:rstrip)
        cut = lines.reject(&:empty?).map { |l| l[/\A */].size }.min.to_i
        new = new.strip
        ctx = text[e.range.begin, 30].to_s.lines.first.to_s.strip
        if lines.size > 1 then "#{where}: insert\n#{lines.map { |l| "      #{l[cut..]}" }.join("\n")}"
        elsif e.replacement.start_with?("\n") || e.replacement.end_with?("\n") || ctx.empty? then "#{where}: add `#{new}`"
        else "#{where}: insert `#{new}` before `#{ctx}`"
        end
      else
        "#{where}: `#{old}` -> `#{e.replacement}`"
      end
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
