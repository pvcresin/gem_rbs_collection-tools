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
  #   self_returns / block_passthrough: [matching calls, calls] (tracepoint)
  #   block_args: [[types of 1st arg], ...]; block_returns; block_self ("receiver"/"caller")
  Evidence = Struct.new(:source, :sigs, :params, :block, :returns, :raises, :calls,
                        :self_returns, :block_passthrough, :block_args, :block_returns, :block_self, :returns_without_block,
                        keyword_init: true) do
    def runtime? = !calls.nil?

    def always?(pair) = pair && pair[1].to_i.positive? && pair[0] == pair[1]

    def to_rbs
      return sigs.join(" | ") if sigs && !sigs.empty?
      return nil unless params || returns

      ps = (params || []).map { |p| GemTypes.param_rbs(p) }.compact.join(", ")
      passthrough = always?(block_passthrough)
      blk_ret = if passthrough then "T"
                elsif (block_returns || []).any? && block_returns.all? { |t| t == "bool" } then "bool"
                else "void"
                end
      blk_params = block_args && !block_args.empty? ? block_args.map { |ts| GemTypes.union(ts) }.join(", ") : "?"
      blk_self = block_self == ["receiver"] ? " [self: instance]" : ""
      fn = "{ (#{blk_params})#{blk_self} -> #{blk_ret} }"
      blk = case (block || []).sort
            when ["yes"] then " #{fn}"
            when %w[no yes] then " ?#{fn}"
            else ""
            end
      if passthrough && !blk.empty?
        with_block = "[T] (#{ps}) #{fn} -> T"
        return with_block if block.sort == ["yes"]

        # Optional block: the value without a block is a separate overload.
        return "(#{ps}) -> #{GemTypes.return_type(returns_without_block || [])} | #{with_block}"
      end
      ret = always?(self_returns) ? "self" : GemTypes.return_type(returns || [])
      "(#{ps})#{blk} -> #{ret}"
    end
  end

  # Order used to pick the draft signature: runtime evidence first.
  PRIORITY = %w[tracepoint rbs_trace lumitrace typeprof rigor tyda yard prototype existing].freeze

  module_function

  # Test doubles seen at runtime are not types the gem works with.
  TEST_DOUBLE = /\A(RSpec::Mocks::|Minitest::Mock\b|Mocha::Mock\b|FlexMock\b|RR::)/

  def union(types)
    ts = types.map { |t| t == "(none)" || t.match?(TEST_DOUBLE) ? nil : t }.compact.uniq
    return "untyped" if ts.empty?
    nilable = ts.delete("nil")
    ts = ts.map { |t| t.include?("(anon)") ? "untyped" : t }.uniq
    ts = drop_empty_generics(ts)
    ts = ["untyped"] if ts.include?("untyped")
    body = ts.empty? ? "nil" : ts.sort.join(" | ")
    return body if body == "nil" || body == "untyped" || !nilable
    ts.size == 1 ? "#{body}?" : "(#{body})?"
  end

  # A union as a method's return type needs parentheses: in
  # `def m: () -> A | B` the `|` would start another overload.
  def return_type(types) = paren(union(types))

  def paren(type)
    depth = 0
    top = type.each_char.any? do |c|
      depth += 1 if "([{".include?(c)
      depth -= 1 if ")]}".include?(c)
      c == "|" && depth.zero?
    end
    top ? "(#{type})" : type
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
require_relative "gem_types/batch"
require_relative "gem_types/update"
