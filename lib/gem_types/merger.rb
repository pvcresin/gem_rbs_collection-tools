# frozen_string_literal: true

module GemTypes
  # Combines evidence from all sources into a draft RBS and a Markdown report.
  class Merger
    # evidence: { source name => { key => Evidence } }
    # classes:  { "Foo::Bar" => { kind:, super: } } from the RBS-producing sources
    # shapes:   tracepoint's per-call-shape lines
    def initialize(evidence:, classes: {}, shapes: [], existing: {})
      @evidence = evidence
      @classes = classes
      @existing = existing
      @shape_lines = group_shapes(shapes)
    end

    def keys
      (@evidence.values.flat_map(&:keys) | @existing.keys).uniq.sort_by { |k| sort_key(k) }
    end

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
        ks.each do |k|
          _, sep, name = GemTypes.split_key(k)
          rbs, src = pick(k)
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
      cmp = ->(list) { list.map(&:to_rbs).compact.map { |s| comparable(s) }.reject { |s| s.match?(/untyped|-> void\b/) }.uniq }
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

    def comparable(sig) = (GemTypes.canonical(sig) || sig).gsub(/\)\??\{\}/, ")")

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
