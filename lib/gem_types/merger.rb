# frozen_string_literal: true

module GemTypes
  # Combines evidence from all sources into a draft RBS and a Markdown report.
  class Merger
    # evidence: { source name => { key => Evidence } }
    # classes:  { "Foo::Bar" => { kind:, super: } } from the RBS-producing sources
    # shapes:   tracepoint's per-call-shape lines
    # defs:     a DefIndex of the library (attrs, private/internal methods)
    def initialize(evidence:, classes: {}, shapes: [], existing: {}, defs: nil)
      @evidence = evidence
      @attrs = defs ? defs.attrs : {}
      @hidden = defs ? defs.hidden : {}
      # The def of each method (the last one when it is defined twice, as
      # Lint reads them), for correcting a drafted signature's structure.
      @defs = defs.is_a?(DefIndex) ? defs.to_h { |d| [d[:key], d] } : {}
      @privatized = privatized_defs(defs.respond_to?(:privatized) ? defs.privatized : [])
      @classes = classes
      @existing = existing
      @shape_lines = group_shapes(shapes)
    end

    # Class info from the sources with the existing RBS's on top: a
    # module only the existing RBS declares must not be drafted as a class.
    def self.with_existing_classes(classes, existing)
      out = classes.dup
      existing.each do |name, info|
        cur = out[name]
        out[name] = if cur.nil? || cur[:kind] != info[:kind] || info[:super] then info
                    else cur
                    end
      end
      out
    end

    def keys
      @keys ||= (@evidence.values.flat_map(&:keys) | @existing.keys).uniq.sort_by { |k| sort_key(k) }
    end

    # Methods left out of the draft: private, protected or documented as
    # internal in the source (an existing RBS entry keeps them in).
    def hidden_keys = @hidden_keys ||= keys.select { |k| @hidden.key?(k) && !@existing.key?(k) }

    # The signature to draft from, and the source it came from. A method
    # only known as an alias gets the signature of the method it aliases.
    def pick(key, seen = [])
      direct = pick_direct(key) and return direct
      if (target = alias_target(key)) && !seen.include?(key)
        owner, sep, = GemTypes.split_key(key)
        return pick("#{owner}#{sep}#{target}", seen + [key])
      end
      ["(*untyped) -> untyped", nil]
    end

    # [signature, source] from the evidence for `key` itself, or nil.
    def pick_direct(key)
      PRIORITY.each do |src|
        e = src == "existing" ? existing_evidence(key) : @evidence.dig(src, key)
        next unless e

        rbs = e.to_rbs
        next if rbs.nil? || rbs.start_with?("(alias of")
        # A runtime source that saw only raising calls has no normal shape.
        next if e.runtime? && e.returns && e.returns.empty? && e.sigs.nil?

        return [rbs, src]
      end
      nil
    end

    # The method `key` aliases, when some source (or the existing RBS) only
    # says that it is an alias.
    def alias_target(key)
      PRIORITY.each do |src|
        e = src == "existing" ? existing_evidence(key) : @evidence.dig(src, key)
        sig = e&.sigs&.find { |x| x.start_with?("(alias of ") } or next
        return sig[/\A\(alias of (.+)\)\z/, 1]
      end
      nil
    end

    def draft
      out = ["# Draft from gem-types. Every line needs checking against the source.", ""]
      by_owner = keys.group_by { |k| GemTypes.split_key(k).first }
      by_owner.sort.each do |owner, ks|
        info = @classes[owner] || { kind: "class" }
        sup = info[:kind] == "class" && info[:super] && !%w[Object BasicObject].include?(info[:super]) ? " < #{superclass(info)}" : ""
        out << "#{info[:kind]} #{owner}#{sup}"
        ks -= hidden_keys
        priv = @privatized[owner] || {}
        privates = []
        ks.each do |k|
          _, sep, name = GemTypes.split_key(k)
          out.concat(entry(owner, k, ks)) unless sep == "#" && priv.key?(name)
        end
        # A module doing `private(*Other.instance_methods(false))`: includers
        # get Other's methods as private ones.
        priv.sort.each do |name, src_key|
          # The better evidence of the two keys (runtime sources record
          # the call under the defining module).
          found = [pick_direct("#{owner}##{name}"), pick_direct(src_key)].compact.min_by { |_, s| PRIORITY.index(s) }
          rbs, src = found || pick(src_key)
          rbs, notes = Skeleton.apply(src_key, rbs, @defs[src_key])
          privates << "  # #{comment(src_key, src)} | from #{src_key}#{notes_text(notes)}"
          privates << "  def #{method_name(name)}: #{rbs}"
        end
        unless privates.empty?
          sources = priv.values.map { |x| GemTypes.split_key(x).first }.uniq.join(", ")
          out << "" << "  private" << "" << "  # #{owner} makes #{sources}'s methods private (private(*X.instance_methods(false)))"
          out.concat(privates)
        end
        out << "end" << ""
      end
      out.join("\n")
    end

    # The draft lines of one method (or attribute) of `owner`.
    def entry(owner, k, ks)
      _, sep, name = GemTypes.split_key(k)
      prefix = sep == "." ? "self." : ""
      base = k.delete_suffix("=")
      rbs, src = pick(k)
      attr = @attrs[base]
      # attr_reader :x with a hand-written `def x=` (or attr_writer :y
      # with `def y`): the def is not part of the attribute.
      attr = nil if attr && (k == base ? attr[:kind] == "writer" : attr[:kind] == "reader")
      if attr
        kind = attr[:kind]
        # A private writer (`private :x=`) leaves a public reader.
        writer_hidden = kind == "accessor" && @hidden.key?("#{base}=") && !@existing.key?("#{base}=")
        kind = "reader" if writer_hidden
        return [] if k.end_with?("=") && kind == "accessor" && ks.include?(base)

        writer = if k != base then [rbs, src]
                 elsif kind != "reader" && keys.include?("#{base}=") then pick("#{base}=")
                 end
        type = attr_type(k == base && src ? rbs : nil, writer && writer[1] ? writer[0] : nil)
        kind = "writer" if kind == "accessor" && !ks.include?(base)
        return ["  # #{comment(k, src)} | attr_#{attr[:kind]} in the source#{writer_hidden ? ' (writer is private)' : ''}",
                "  attr_#{kind} #{prefix}#{method_name(name.delete_suffix('='))}: #{type}"]
      end
      if !pick_direct(k) && (target = alias_target(k))
        target_key = "#{owner}#{sep}#{target}"
        if ks.include?(target_key)
          return ["  # #{comment(k, 'alias')}", "  alias #{prefix}#{method_name(name)} #{prefix}#{method_name(target)}"]
        end
      end
      rbs, notes = Skeleton.apply(k, rbs, def_of(k))
      rbs = void_return(rbs) if name == "initialize" && sep == "#"
      # module_function: a singleton method and a private instance method.
      prefix = "self?." if sep == "." && @hidden["#{owner}##{name}"] == "module_function"
      ["  # #{comment(k, src)}#{notes_text(notes)}", "  def #{prefix}#{method_name(name)}: #{rbs}"]
    end

    # The def a drafted key stands for: its own, initialize for `.new`, the
    # def of a method a module makes private from another one, or the
    # nearest superclass's def of an inherited method.
    def def_of(key, depth = 0)
      owner, sep, name = GemTypes.split_key(key)
      own = @defs[key] || (key.end_with?(".new") && @defs["#{owner}#initialize"]) ||
            (sep == "#" && (src = @privatized.dig(owner, name)) ? @defs[src] : nil)
      return own if own

      sup = @classes.dig(owner, :super)&.delete_prefix("::")
      return nil if sup.nil? || depth > 10 || %w[Object BasicObject].include?(sup)

      def_of("#{sup}#{sep}#{name}", depth + 1)
    end

    # A method name as RBS needs it: names Ruby allows but RBS does not
    # parse bare (`valid?_with_rescue`) are quoted with backticks.
    def method_name(name)
      @method_names ||= {}
      @method_names[name] ||= begin
        RBS::Parser.parse_signature("class X\n  def #{name}: () -> void\nend\n")
        name
      rescue RBS::ParsingError
        "`#{name}`"
      end
    end

    def report
      out = ["# gem-types report", ""]
      out << "| source | methods |" << "|---|---|"
      @evidence.each { |src, h| out << "| #{src} | #{h.size} |" }
      out << ""
      flagged = keys.select { |k| flags(k).any? }
      out << "## Needs attention (#{flagged.size})" << ""
      flagged.each { |k| out << "- `#{k}`: #{flags(k).join('; ')}" }
      unless hidden_keys.empty?
        out << "" << "## Left out of the draft (#{hidden_keys.size})" << ""
        hidden_keys.each { |k| out << "- `#{k}`: #{@hidden[k]}" }
      end
      out << "" << "## Methods" << ""
      keys.each do |k|
        out << "### `#{k}`" << ""
        f = flags(k)
        out << "_#{f.join('; ')}_" << "" unless f.empty?
        (PRIORITY - ["existing"]).each do |src|
          e = @evidence.dig(src, k) or next
          extra = []
          extra << "#{e.calls} calls" if e.calls && src == "tracepoint"
          extra << "raises #{e.raises.join(', ')}" if e.raises && !e.raises.empty?
          out << "- #{src}#{extra.empty? ? '' : " (#{extra.join(', ')})"}: `#{e.to_rbs}`"
        end
        out << "- existing: `#{@existing[k].join(' | ')}`" if @existing[k]
        if (tp = @evidence.dig("tracepoint", k))
          notes = []
          notes << "always returned self" if tp.always?(tp.self_returns)
          notes << "returned what the block returned" if tp.always?(tp.block_passthrough)
          notes << "block ran with self = the receiver (DSL)" if tp.block_self == ["receiver"]
          notes << "block returned #{tp.block_returns.join(' | ')}" if tp.block_returns && !tp.block_returns.empty?
          if tp.return_tuples && !tp.return_tuples.empty?
            notes << "returned Arrays of tagged tuples (consider a union of tuple types over Array[untyped]): #{tp.return_tuples.join(' | ')}"
          end
          out << "- tracepoint notes: #{notes.join('; ')}" unless notes.empty?
        end
        if (lines = @shape_lines[k]) && !lines.empty?
          out << "- call shapes:" << "  ```" << lines.map { |l| "  #{l.strip}" } << "  ```"
        end
        out << ""
      end
      out.flatten.join("\n")
    end

    def flags(key)
      f = []
      runtime = %w[tracepoint rbs_trace lumitrace].map { |s| @evidence.dig(s, key) }.compact
      static = %w[typeprof tyda rigor].map { |s| @evidence.dig(s, key) }.compact
      docs = @evidence.dig("yard", key)
      f << "no runtime evidence (tests never called it)" if runtime.empty? && (!static.empty? || docs)
      tp = @evidence.dig("tracepoint", key)
      f << "raises in tests: #{tp.raises.join(', ')} (check for negative tests)" if tp && !tp.raises.empty?
      f << "only raising calls observed" if tp && tp.returns.empty? && tp.calls.positive?
      if @existing.any?
        f << "not in existing RBS" if !@existing.key?(key) && !runtime.empty?
        alias_only = @existing[key]&.all? { |sig| sig.start_with?("(alias of") }
        f << "in existing RBS but not observed" if @existing.key?(key) && runtime.empty? && !alias_only
      end
      # Sources that left something untyped, or that do not record blocks
      # (rbs-trace), would only add noise: compare typed parts, without blocks.
      owner, sep, = GemTypes.split_key(key)
      cmp = lambda do |list|
        list.filter_map do |e|
          s = e.to_rbs or next
          s = self_to_owner(s, owner, sep)
          c = comparable(s) or next
          next if c.match?(/untyped|-> void\b/)
          # Method type variables (`[T] (T) -> T`) say what tracepoint can
          # only see as concrete types: not comparable.
          next unless GemTypes.projection(s)

          [e.source, s]
        end
      end
      same = ->((sa, a), (sb, b)) { same_types?(sa, a, sb, b) }
      rt = cmp.(runtime)
      f << "runtime sources disagree" if rt.combination(2).any? { |a, b| !same.(a, b) }
      # Without type arguments Lumitrace agrees with too much: it is the
      # reference only when no other runtime source has a comparable type.
      ref = rt.reject { |src, _| src == "lumitrace" }
      ref = rt if ref.empty?
      st = cmp.(static)
      if !ref.empty? && st.any? { |x| ref.none? { |r| same.(x, r) } }
        f << "static inference differs from runtime"
      end
      dc = docs ? cmp.([docs]) : []
      f << "YARD docs differ from runtime" if !ref.empty? && dc.any? { |x| ref.none? { |r| same.(x, r) } }
      f
    end

    private

    # Whether two sources' signatures say the same per slot, apart from
    # what one of the tools cannot record: Lumitrace sees classes without
    # type arguments, and a rest parameter as the whole Array (Hash);
    # rbs-trace writes `*nil` for a call without rest arguments; both write
    # Class (or Module) where tracepoint names singleton(Foo); tyda leaves
    # constants relative. Test doubles are not types of the gem.
    def same_types?(src_a, sig_a, src_b, sig_b)
      srcs = [src_a, src_b]
      erase = srcs.include?("lumitrace")
      pa = GemTypes.projection(sig_a, erase_args: erase)
      pb = GemTypes.projection(sig_b, erase_args: erase)
      return false unless pa && pb

      classes_only = srcs.intersect?(%w[lumitrace rbs_trace])
      [pa, pb].map do |pr|
        pr.to_h do |slot, types|
          types = [] if erase && %w[* **].include?(slot)
          types -= ["nil"] if slot == "*" && srcs.include?("rbs_trace")
          types = types.reject { |t| t.match?(TEST_DOUBLE) }
          types = types.map { |t| t.start_with?("singleton(") || %w[Class Module].include?(t) ? "Module" : t }.uniq.sort if classes_only
          # tyda writes constants relative to the namespace (`Expression`).
          types = types.map { |t| t.gsub(/\b(?:[A-Z]\w*::)+(?=[A-Z])/, "") }.uniq.sort if srcs.include?("tyda")
          [slot, types]
        end
      end.uniq.size == 1
    end

    def comparable(sig, owner = nil, sep = "#")
      sig = self_to_owner(sig, owner, sep) if owner
      (GemTypes.canonical(sig) || sig).gsub(/\)\??\{\}/, ")")
    end

    # `self` as the type it stands for: the instance for `#` keys,
    # singleton(Owner) for `.` keys (`self:` in a block is not a type).
    def self_to_owner(sig, owner, sep)
      sig.gsub(/\bself\b(?!:)/, sep == "." ? "singleton(#{owner})" : owner)
    end

    def void_return(sig)
      mts, dots = GemTypes.overloads(sig)
      return sig unless mts

      list = mts.map do |mt|
        next mt.to_s unless mt.type.is_a?(RBS::Types::Function) || mt.type.is_a?(RBS::Types::UntypedFunction)

        mt.update(type: mt.type.with_return_type(RBS::Types::Bases::Void.new(location: nil))).to_s
      end
      list << "..." if dots
      list.uniq.join(" | ")
    end

    # The attribute type from a reader's return type and a writer's first
    # parameter type, whichever is known and usable as an attribute type.
    def attr_type(reader_sig, writer_sig)
      candidates = []
      if (mts, = GemTypes.overloads(reader_sig)) && mts
        candidates << mts.first.type.return_type if mts.size == 1 && plain_method?(mts.first)
      end
      if (mts, = GemTypes.overloads(writer_sig)) && mts
        f = mts.first.type
        candidates << f.required_positionals.first&.type if mts.size == 1 && plain_method?(mts.first)
      end
      t = candidates.compact.find do |c|
        ![RBS::Types::Bases::Void, RBS::Types::Bases::Any, RBS::Types::Bases::Self].include?(c.class)
      end
      t ? t.to_s : "untyped"
    end

    def plain_method?(mt) = mt.type.is_a?(RBS::Types::Function) && mt.type_params.empty?

    def superclass(info)
      args = info[:super_args]
      args && !args.empty? ? "#{info[:super]}[#{args.join(', ')}]" : info[:super]
    end

    def notes_text(notes) = notes.empty? ? "" : " | structure: #{notes.join('; ')}"

    # { module => { method name => key of the def } } for modules doing
    # `private(*Other.instance_methods(false))`: Other's public and
    # protected instance methods, Other resolved from the module's nesting.
    def privatized_defs(list)
      out = {}
      list.each do |mod, other|
        parts = mod.split("::")
        cands = if other.start_with?("::") then [other.delete_prefix("::")]
                else parts.size.downto(0).map { |i| (parts[0...i] + [other]).join("::") }
                end
        found = cands.find { |c| @defs.each_key.any? { |k| k.start_with?("#{c}#") } } or next
        @defs.each_key do |k|
          next unless k.start_with?("#{found}#")

          name = k.delete_prefix("#{found}#")
          next if name == "initialize" || %w[private module_function].include?(@hidden[k])

          (out[mod] ||= {})[name] ||= k
        end
      end
      out
    end

    def existing_evidence(key)
      sigs = @existing[key] or return nil
      Evidence.new(source: "existing", sigs: sigs)
    end

    def comment(key, picked)
      parts = []
      tp = @evidence.dig("tracepoint", key)
      parts << "observed #{tp.calls} calls#{tp.raises.empty? ? '' : " (raises #{tp.raises.join(', ')})"}" if tp
      present = (PRIORITY - ["existing"]).select { |s| @evidence.dig(s, key) }
      parts << "from #{picked || 'none'}"
      parts << "also: #{(present - [picked]).join(', ')}" unless (present - [picked]).empty?
      parts.join(" | ")
    end

    def group_shapes(lines)
      out = Hash.new { |h, k| h[k] = [] }
      current = nil
      lines.each do |l|
        if l.start_with?(" ")
          out[current] |= [l] if current
        else
          current = l[/\A(.+?): \(/, 1]
        end
      end
      out
    end

    def sort_key(key)
      owner, sep, name = GemTypes.split_key(key)
      [owner, sep == "." ? 0 : 1, name]
    end
  end
end
