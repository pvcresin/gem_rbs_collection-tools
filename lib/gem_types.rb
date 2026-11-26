# frozen_string_literal: true

# Collects type evidence for a gem from several tools and merges it into a
# draft RBS plus a per-method comparison report.
#
# Every source is turned into the same shape: a Hash from method key
# ("Foo::Bar#baz" or "Foo::Bar.baz") to an Evidence.
require "shellwords"

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

      ps = GemTypes.ordered_params(params || []).map { |p| GemTypes.param_rbs(p) }.compact.join(", ")
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
    return body if ts.size == 1 && body.end_with?("?") && body.delete_suffix("?").match?(PLAIN_TYPE)
    # `T?` binds to the last token: `:foo?` is another symbol, `^() -> A?`
    # makes the proc's return optional, `A??` does not parse.
    ts.size == 1 && body.match?(PLAIN_TYPE) ? "#{body}?" : "(#{body})?"
  end

  # A (generic) class or interface name, or a base type: safe before `?`.
  PLAIN_TYPE = /\A(?:(?:::)?_?[A-Z]\w*(?:::[A-Z]\w*)*(?:\[.*\])?|bool|singleton\([\w:]+\))\z/m

  # Parameters in the order RBS requires: leading required, optional,
  # the first *rest, trailing required, keywords, the first **rest. Runtime
  # observation can list them in another order or repeat a rest.
  def ordered_params(params)
    lead, opt, trail, keys = [], [], [], []
    rest = keyrest = nil
    params.each do |p|
      case p[:kind]
      when "req" then (rest || !opt.empty? ? trail : lead) << p
      when "opt" then opt << p unless rest # a rest already takes the extra arguments
      when "rest" then rest ||= p
      when "keyreq", "key" then keys << p unless keys.any? { |k| k[:name] == p[:name] }
      when "keyrest" then keyrest ||= p
      end
    end
    lead + opt + [rest].compact + trail + keys + [keyrest].compact
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

  # The overloads of an RBS method type string ("a | b", maybe ending in
  # `| ...`): [[RBS::MethodType, ...], overloading?], or nil if it does not
  # parse. Splitting on `|` by hand is wrong (`(A) -> B | [T] (T) -> T`,
  # unions in parentheses), so the parser does it.
  def overloads(sig)
    return nil if sig.nil? || sig.include?("\n")

    _, _, decls = RBS::Parser.parse_signature("class X\n  def m: #{sig}\nend\n")
    return nil unless decls.size == 1 && decls.first.members.size == 1

    m = decls.first.members.first
    return nil unless m.is_a?(RBS::AST::Members::MethodDefinition)

    [m.overloads.map(&:method_type), m.overloading?]
  rescue RBS::ParsingError, StandardError
    nil
  end

  # A comparable form of an RBS method type (or "a | b" overloads): types
  # only (no parameter names), overloads with the same parameters merged,
  # `T?` and `T | nil` treated alike. Returns nil if it does not parse.
  def canonical(sig)
    mts, dots = overloads(sig)
    return nil unless mts

    list = mts.map do |mt|
      f = mt.type
      next [mt.to_s, []] unless f.is_a?(RBS::Types::Function)

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
      tparams = mt.type_params.empty? ? "" : "[#{mt.type_params.map(&:to_s).join(', ')}] "
      ["#{tparams}(#{params.join(', ')})#{block}", flat_types(f.return_type)]
    end
    merged = list.group_by(&:first).map do |params, l|
      rets = drop_empty_generics(l.flat_map(&:last).uniq)
      # rbs-trace writes `void` when the caller ignored the value.
      rets -= ["void"] if rets.size > 1
      rets = rets.sort
      "#{params} -> #{rets.join(' | ')}"
    end
    merged = merged.sort
    merged << "..." if dots
    merged.join(" || ")
  end

  # What a signature says per slot, for comparing sources that write the
  # same thing differently (`(A | B) -> C` and `(A) -> C | (B) -> C`):
  # { slot => sorted member types } for every positional and keyword slot
  # plus the return type, merged over the overloads. Blocks are ignored.
  # erase_args drops type arguments (Lumitrace records classes only).
  # nil if it does not parse or uses method type variables.
  def projection(sig, erase_args: false)
    mts, = overloads(sig)
    return nil unless mts

    slots = Hash.new { |h, k| h[k] = [] }
    rets = []
    mts.each do |mt|
      f = mt.type
      return nil unless f.is_a?(RBS::Types::Function) && mt.type_params.empty?

      add = ->(slot, t) { slots[slot] |= member_names(t, erase_args) }
      f.required_positionals.each_with_index { |p, i| add.("r#{i}", p.type) }
      f.optional_positionals.each_with_index { |p, i| add.("o#{i}", p.type) }
      add.("*", f.rest_positionals.type) if f.rest_positionals
      f.trailing_positionals.each_with_index { |p, i| add.("t#{i}", p.type) }
      f.required_keywords.each { |k, p| add.("k:#{k}", p.type) }
      f.optional_keywords.each { |k, p| add.("?k:#{k}", p.type) }
      add.("**", f.rest_keywords.type) if f.rest_keywords
      rets |= member_names(f.return_type, erase_args)
    end
    rets -= ["void"] if rets.size > 1
    slots.transform_values(&:sort).sort.to_h.merge(ret: rets.sort)
  end

  def member_names(type, erase_args = false)
    flat_types(type).zip(flat_type_objects(type)).map do |name, t|
      next name unless erase_args

      case t
      when RBS::Types::ClassInstance, RBS::Types::Interface, RBS::Types::Alias then t.name.to_s.delete_prefix("::")
      when RBS::Types::Tuple then "Array"
      when RBS::Types::Record then "Hash"
      else name
      end
    end.uniq
  end

  # The members flat_types names, as type objects (nil for added `nil`s).
  def flat_type_objects(type)
    case type
    when RBS::Types::Union then type.types.flat_map { |t| flat_type_objects(t) }
    when RBS::Types::Optional then flat_type_objects(type.type) + [nil]
    else [type]
    end
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
    when "req" then "#{t} #{n}".rstrip
    when "opt" then "?#{t} #{n}".rstrip
    when "rest" then "*#{t} #{n}".rstrip
    when "keyreq" then "#{n}: #{t}"
    when "key" then "?#{n}: #{t}"
    when "keyrest" then "**#{t} #{n}".rstrip
    end
  end

  # Seconds a test command may run (GEM_TYPES_TEST_TIMEOUT overrides).
  TEST_TIMEOUT = Integer(ENV.fetch("GEM_TYPES_TEST_TIMEOUT", "1800"))

  # A shell command that runs `cmd` with the test timeout, so a hanging
  # suite cannot block a run forever.
  def timed(cmd) = "timeout -k 30 #{TEST_TIMEOUT} bash -c #{cmd.shellescape}"

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
require_relative "gem_types/lint"
require_relative "gem_types/batch"
require_relative "gem_types/collect"
require_relative "gem_types/update"
require_relative "gem_types/pr_text"
