# frozen_string_literal: true

# Collects type evidence for a gem from several tools and merges it into a
# draft RBS plus a per-method comparison report.
#
# Every source is turned into the same shape: a Hash from method key
# ("Foo::Bar#baz" or "Foo::Bar.baz") to an Evidence.
module GemTypes
  ROOT = File.expand_path("..", __dir__)
  HOOKS = File.join(__dir__, "gem_types", "hooks")
  LIBEXEC = File.join(ROOT, "libexec")

  # What one source says about one method.
  #   sigs:    RBS method types as strings (overloads), for RBS-producing sources
  #   params:  [{kind:, name:, types: [...]}], for runtime observation
  #   block:   ["yes", "no"] seen
  #   returns: types seen on normal return
  #   raises:  exception classes seen
  #   calls:   number of calls observed (runtime sources)
  Evidence = Struct.new(:source, :sigs, :params, :block, :returns, :raises, :calls, keyword_init: true) do
    def runtime? = !calls.nil?

    def to_rbs
      return sigs.join(" | ") if sigs && !sigs.empty?
      return nil unless params || returns

      ps = (params || []).map { |p| GemTypes.param_rbs(p) }.compact.join(", ")
      blk = case (block || []).sort
            when ["yes"] then " { (?) -> untyped }"
            when %w[no yes] then " ?{ (?) -> untyped }"
            else ""
            end
      "(#{ps})#{blk} -> #{GemTypes.union(returns || [])}"
    end
  end

  # Order used to pick the draft signature: runtime evidence first.
  PRIORITY = %w[tracepoint rbs_trace lumitrace typeprof rigor tyda yard prototype existing].freeze

  module_function

  def union(types)
    ts = types.map { |t| t == "(none)" ? nil : t }.compact.uniq
    return "untyped" if ts.empty?
    nilable = ts.delete("nil")
    ts = ts.map { |t| t.include?("(anon)") ? "untyped" : t }.uniq
    ts = drop_empty_generics(ts)
    ts = ["untyped"] if ts.include?("untyped")
    body = ts.empty? ? "nil" : ts.sort.join(" | ")
    return body if body == "nil" || body == "untyped" || !nilable
    ts.size == 1 ? "#{body}?" : "(#{body})?"
  end

  # Array[untyped]/Hash[untyped, untyped] usually come from empty
  # collections; drop them when a typed variant of the same class is present.
  def drop_empty_generics(types)
    types.reject do |t|
      next false unless (m = t.match(/\A(\w[\w:]*)\[untyped(?:, untyped)?\]\z/))

      types.any? { |o| o != t && o.start_with?("#{m[1]}[") }
    end
  end

  # A comparable form of an RBS method type (or "a | b" overloads): types
  # only (no parameter names), overloads with the same parameters merged,
  # `T?` and `T | nil` treated alike. Returns nil if it does not parse.
  def canonical(sig)
    overloads = sig.split(/ \| (?=\()/).map do |o|
      mt = RBS::Parser.parse_method_type(o)
      f = mt.type
      next [o, []] unless f.is_a?(RBS::Types::Function)

      params = [
        f.required_positionals.map { |p| p.type.to_s },
        f.optional_positionals.map { |p| "?#{p.type}" },
        f.rest_positionals ? ["*#{f.rest_positionals.type}"] : [],
        f.trailing_positionals.map { |p| p.type.to_s },
        f.required_keywords.sort.map { |k, p| "#{k}: #{p.type}" },
        f.optional_keywords.sort.map { |k, p| "?#{k}: #{p.type}" },
        f.rest_keywords ? ["**#{f.rest_keywords.type}"] : []
      ].flatten
      block = mt.block ? (mt.block.required ? "{}" : "?{}") : ""
      ["(#{params.join(', ')})#{block}", flat_types(f.return_type)]
    end
    merged = overloads.group_by(&:first).map do |params, list|
      rets = drop_empty_generics(list.flat_map(&:last).uniq)
      # rbs-trace writes `void` when the caller ignored the value.
      rets -= ["void"] if rets.size > 1
      rets = rets.sort
      "#{params} -> #{rets.join(' | ')}"
    end
    merged.sort.join(" || ")
  rescue RBS::ParsingError, StandardError
    nil
  end

  def flat_types(type)
    case type
    when RBS::Types::Union then type.types.flat_map { |t| flat_types(t) }
    when RBS::Types::Optional then flat_types(type.type) + ["nil"]
    when RBS::Types::Bases::Bool then ["bool"]
    when RBS::Types::Literal
      [true, false].include?(type.literal) ? ["bool"] : [type.to_s]
    else [type.to_s.delete_prefix("::")]
    end
  end

  def param_rbs(param)
    t = union(param[:types] || [])
    n = param[:name]
    case param[:kind]
    when "req" then "#{t} #{n}"
    when "opt" then "?#{t} #{n}"
    when "rest" then "*#{t} #{n}"
    when "keyreq" then "#{n}: #{t}"
    when "key" then "?#{n}: #{t}"
    when "keyrest" then "**#{t} #{n}"
    end
  end

  # Splits "A::B#m" / "A::B.m" into [owner, separator, name].
  def split_key(key)
    i = key.rindex(/[#.]/)
    [key[0...i], key[i], key[(i + 1)..]]
  end
end

require_relative "gem_types/rbs_reader"
require_relative "gem_types/sources"
require_relative "gem_types/merger"
require_relative "gem_types/verify"
