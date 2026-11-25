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
      @classes = classes
      @existing = existing
      @shape_lines = group_shapes(shapes)
    end

    def keys
      @keys ||= (@evidence.values.flat_map(&:keys) | @existing.keys).uniq.sort_by { |k| sort_key(k) }
    end

    # Methods left out of the draft: private, protected or documented as
    # internal in the source (an existing RBS entry keeps them in).
    def hidden_keys = @hidden_keys ||= keys.select { |k| @hidden.key?(k) && !@existing.key?(k) }

    # The signature to draft from, and the source it came from.
    def pick(key)
      PRIORITY.each do |src|
        e = src == "existing" ? existing_evidence(key) : @evidence.dig(src, key)
        next unless e

        rbs = e.to_rbs
        next if rbs.nil? || rbs.start_with?("(alias of")
        # A runtime source that saw only raising calls has no normal shape.
        next if e.runtime? && e.returns && e.returns.empty? && e.sigs.nil?

        return [rbs, src]
      end
      ["(*untyped) -> untyped", nil]
    end

    def draft
      out = ["# Draft from gem-types. Every line needs checking against the source.", ""]
      by_owner = keys.group_by { |k| GemTypes.split_key(k).first }
      by_owner.sort.each do |owner, ks|
        info = @classes[owner] || { kind: "class" }
        sup = info[:kind] == "class" && info[:super] && !%w[Object BasicObject].include?(info[:super]) ? " < #{info[:super]}" : ""
        out << "#{info[:kind]} #{owner}#{sup}"
        ks -= hidden_keys
        ks.each do |k|
          _, sep, name = GemTypes.split_key(k)
          base = k.delete_suffix("=")
          rbs, src = pick(k)
          if (attr = @attrs[base])
            next if k.end_with?("=") && attr[:kind] == "accessor" && ks.include?(base)

            writer = k == base ? (pick("#{base}=") if keys.include?("#{base}=")) : [rbs, src]
            type = attr_type(k == base && src ? rbs : nil, writer && writer[1] ? writer[0] : nil)
            kind = attr[:kind] == "accessor" && !ks.include?(base) ? "writer" : attr[:kind]
            out << "  # #{comment(k, src)} | attr_#{attr[:kind]} in the source"
            out << "  attr_#{kind} #{sep == '.' ? 'self.' : ''}#{name.delete_suffix('=')}: #{type}"
            next
          end
          rbs = void_return(rbs) if name == "initialize" && sep == "#"
          out << "  # #{comment(k, src)}"
          out << "  def #{sep == '.' ? 'self.' : ''}#{name}: #{rbs}"
        end
        out << "end" << ""
      end
      out.join("\n")
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
      owner = GemTypes.split_key(key).first
      cmp = ->(list) { list.map(&:to_rbs).compact.map { |s| comparable(s, owner) }.reject { |s| s.match?(/untyped|-> void\b/) }.uniq }
      rt = cmp.(runtime)
      f << "runtime sources disagree" if rt.size > 1
      st = cmp.(static)
      if !rt.empty? && !st.empty? && (st - rt).any?
        f << "static inference differs from runtime"
      end
      dc = docs ? cmp.([docs]) : []
      f << "YARD docs differ from runtime" if !rt.empty? && !dc.empty? && (dc - rt).any?
      f
    end

    private

    def comparable(sig, owner = nil)
      sig = sig.gsub(/\bself\b(?!:)/, owner) if owner
      (GemTypes.canonical(sig) || sig).gsub(/\)\??\{\}/, ")")
    end

    def void_return(sig)
      sig.split(/ \| (?=\(|\[)/).map do |o|
        mt = RBS::Parser.parse_method_type(o)
        mt.update(type: mt.type.with_return_type(RBS::Types::Bases::Void.new(location: nil))).to_s
      rescue StandardError
        o
      end.join(" | ")
    end

    # The attribute type from a reader's return type and a writer's
    # parameter type, whichever is known and typed.
    def attr_type(reader_sig, writer_sig)
      r = reader_sig && reader_sig[/-> (.+)\z/, 1]
      w = writer_sig && writer_sig[/\A\((.+?)(?: \w+)?\) ->/, 1]
      [r, w].compact.reject { |t| t == "untyped" || t.start_with?("*", "?") || t.include?(") ->") }.first || "untyped"
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
