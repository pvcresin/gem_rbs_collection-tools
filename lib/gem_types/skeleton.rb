# frozen_string_literal: true

module GemTypes
  # Corrects the structure of a drafted signature from the method's def
  # (a DefIndex entry), keeping the types the evidence gave per slot:
  # parameter kinds, count and names, the keyword set, whether a block is
  # taken and whether it is optional, the block's parameter count and
  # `[self: X]`, and nil in the return type. These are the mistakes
  # `gem-types lint` reports; a corrected signature has none of them, so
  # what remains for the author is choosing the types.
  module Skeleton
    module_function

    # [signature, notes]: the corrected signature and a short note for each
    # correction (written next to the declaration in the draft). The
    # signature is returned unchanged when it does not parse or the
    # corrected one would not.
    def apply(key, sig, src)
      return [sig, []] unless src

      mts, dots = GemTypes.overloads(sig)
      return [sig, []] unless mts

      notes = []
      ctor = key.end_with?("#initialize", ".new")
      shape = src[:shape] || []
      mts = params(mts, shape, notes)
      mts = block(mts, src[:block], shape, notes) if src[:block]
      mts = nil_return(mts, src, notes) unless ctor || key.end_with?("=")
      list = mts.map(&:to_s).uniq
      list << "..." if dots
      out = list.join(" | ")
      return [sig, []] if out == sig || !GemTypes.overloads(out)

      [out, notes.uniq]
    end

    def untyped = RBS::Types::Bases::Any.new(location: nil)

    # A parameter name RBS accepts (`class`, `type` and the like are not).
    def param_name(name)
      return nil if name.nil? || name.empty?

      @param_names ||= {}
      return @param_names[name] if @param_names.key?(name)

      @param_names[name] = begin
        RBS::Parser.parse_method_type("(untyped #{name}) -> void").type.required_positionals.first.name&.to_s == name ? name.to_sym : nil
      rescue RBS::ParsingError
        nil
      end
    end

    def param(type, name) = RBS::Types::Function::Param.new(type: type || untyped, name: param_name(name), location: nil)

    # --- parameters ---

    # Positional parameters are rebuilt from the def when some overload
    # cannot be called the way the def can (too few or too many arguments,
    # a rest the def does not take, a default the overloads all require).
    # Overloads that narrow a def's arity (`(String) | (String, Integer)`
    # for `def m(a, b = nil)`) are kept. Keywords follow the def whenever it
    # takes keywords; a def without any keeps the evidence's keywords (an
    # options Hash written as keywords).
    def params(mts, shape, notes)
      return mts if shape.empty? && mts.all? { |mt| mt.type.is_a?(RBS::Types::Function) && plain?(mt.type) }
      return mts if shape.any? { |p| p[:kind] == "fwd" }

      lead = shape.select { |p| p[:kind] == "req" }
      opt = shape.select { |p| p[:kind] == "opt" }
      rest = shape.find { |p| p[:kind] == "rest" }
      post = shape.select { |p| p[:kind] == "post" }
      kws = shape.select { |p| %w[keyreq key keyrest].include?(p[:kind]) }
      nokey = shape.any? { |p| p[:kind] == "nokey" }
      positional_ok = positional_conforms?(mts.map(&:type), lead.size + post.size, opt.size, rest)
      mts.map do |mt|
        f = mt.type
        f = RBS::Types::Function.empty(f.return_type) unless f.is_a?(RBS::Types::Function)
        g = f
        unless positional_ok
          g = rebuild_positionals(f, shape, lead, opt, rest, post)
          notes << "parameters from the def"
        end
        # Keywords on a def without any reach a trailing `opts = {}` or
        # `*args` as a Hash; with neither they are an ArgumentError.
        # Keywords named like the def's positional parameters are a
        # generator's guess, not an options Hash.
        positional_names = shape.filter_map { |p| p[:name] if %w[req opt rest post].include?(p[:kind]) }
        guessed = (g.required_keywords.keys + g.optional_keywords.keys).any? { |k| positional_names.include?(k.to_s) }
        if !kws.empty? || nokey || (opt.empty? && !rest) || guessed
          h = rebuild_keywords(g, kws)
          notes << "keywords from the def" if h.param_to_s != g.param_to_s
          g = h
        elsif g.rest_keywords && Lint.untyped?(g.rest_keywords.type)
          # `**untyped` names nothing the trailing Hash parameter takes.
          g = g.update(rest_keywords: nil)
          notes << "keywords from the def"
        end
        g.equal?(mt.type) ? mt : mt.update(type: g)
      end
    end

    def plain?(f) = f.required_positionals.empty? && f.optional_positionals.empty? && f.rest_positionals.nil? &&
                    f.trailing_positionals.empty? && f.required_keywords.empty? && f.optional_keywords.empty? && f.rest_keywords.nil?

    def positional_conforms?(fns, req, opt, rest)
      return false unless fns.all? { |f| f.is_a?(RBS::Types::Function) }

      need = fns.map { |f| f.required_positionals.size + f.trailing_positionals.size }
      total = fns.map { |f| f.required_positionals.size + f.optional_positionals.size + f.trailing_positionals.size }
      return false if need.any? { |n| n < req }
      # A default makes the argument optional in some overload.
      return false if opt.positive? && need.min != req
      return true if rest

      fns.none?(&:rest_positionals) && total.max == req + opt
    end

    def rebuild_positionals(f, shape, lead, opt, rest, post)
      flat = f.required_positionals + f.optional_positionals
      all = flat + [f.rest_positionals].compact + f.trailing_positionals
      names = shape.map { |p| p[:name] }.compact
      by_name = all.select(&:name).to_h { |p| [p.name.to_s, p.type] }
      # By name first (runtime sources and prototype use the def's names),
      # then by position when the evidence's parameter there has no name
      # the def uses elsewhere, then the type of the evidence's rest when the
      # def has none (`*String args` for `def initialize(a, b)`).
      spread = rest.nil? ? f.rest_positionals&.type : nil
      at = lambda do |p, ev|
        next by_name[p[:name]] if p[:name] && by_name.key?(p[:name])
        next ev.type if ev && (ev.name.nil? || !names.include?(ev.name.to_s))

        p[:kind] == "rest" ? nil : spread
      end
      trail = f.trailing_positionals
      f.update(
        required_positionals: lead.each_with_index.map { |p, i| param(at.(p, flat[i]), p[:name]) },
        optional_positionals: opt.each_with_index.map { |p, j| param(at.(p, flat[lead.size + j]), p[:name]) },
        rest_positionals: rest && param(at.(rest, f.rest_positionals), rest[:name]),
        trailing_positionals: post.each_with_index.map do |p, k|
          ev = trail.empty? ? flat[lead.size + opt.size + k] : trail[k]
          param(at.(p, ev), p[:name])
        end
      )
    end

    # Keywords exactly as the def has them (types by name). A `**opts` keeps
    # the evidence's other keywords, which name what opts takes.
    def rebuild_keywords(f, kws)
      ev = f.required_keywords.merge(f.optional_keywords)
      own = kws.map { |p| p[:name]&.to_sym }.compact
      keyrest = kws.find { |p| p[:kind] == "keyrest" }
      req = kws.select { |p| p[:kind] == "keyreq" }.to_h { |p| [p[:name].to_sym, param(ev[p[:name].to_sym]&.type, nil)] }
      opt = kws.select { |p| p[:kind] == "key" }.to_h { |p| [p[:name].to_sym, param(ev[p[:name].to_sym]&.type, nil)] }
      if keyrest
        f.required_keywords.each { |k, p| req[k] ||= p unless own.include?(k) }
        f.optional_keywords.each { |k, p| opt[k] ||= p unless own.include?(k) }
      end
      f.update(required_keywords: req, optional_keywords: opt,
               rest_keywords: keyrest && param(f.rest_keywords&.type, keyrest[:name]))
    end

    # --- blocks ---

    def block(mts, u, shape, notes)
      param_kind = shape.find { |p| p[:kind] == "block" }
      fwd = shape.any? { |p| p[:kind] == "fwd" }
      named = param_kind && param_kind[:name]
      takes = !u[:yields].empty? || u[:guarded] || u[:self_eval] || u[:stored] || named
      # Neither yields nor takes a block in any way: no overload has one.
      if !takes && !u[:forwarded] && !param_kind && !fwd
        if mts.any?(&:block)
          notes << "no block (the source neither yields nor takes one)"
          mts = mts.map { |mt| mt.block ? mt.update(block: nil) : mt }
        end
        return mts
      end
      if mts.none?(&:block) && takes
        # Required only when the method itself calls (or keeps) the block
        # unconditionally; a block it only passes on may be nil.
        required = u[:enum] || (!u[:guarded] && (!u[:yields].empty? || u[:self_eval] || u[:stored]))
        blk = RBS::Types::Block.new(type: block_function(yield_arity(u), nil), required: required,
                                    self_type: u[:self_eval] ? self_type(u) : nil)
        notes << "#{required ? '' : 'optional '}block added (the source #{u[:yields].empty? ? 'takes &block' : 'yields'})"
        mts = mts.map { |mt| mt.update(block: blk) }
      end
      with = mts.select(&:block)
      return mts if with.empty?

      passed_on = u[:forwarded] && u[:yields].empty? && !u[:self_eval] && !u[:stored]
      if mts.all?(&:block) && with.all? { |mt| mt.block.required } && !u[:enum] && (u[:guarded] || passed_on)
        notes << (u[:guarded] ? "block optional (the source checks for it)" : "block optional (the source only passes it on: check the callee)")
        mts = mts.map { |mt| mt.update(block: with_block(mt.block, required: false)) }
      end
      mts = enumerator(mts, notes) if u[:enum]
      n = yield_arity(u)
      mts = mts.map do |mt|
        b = mt.block or next mt
        if n && !arity_fits?(b.type, n)
          notes << "block takes #{n} argument#{n == 1 ? '' : 's'} (the source yields #{n})"
          b = with_block(b, type: block_function(n, b.type))
        end
        if u[:self_eval] && b.self_type.nil?
          notes << "block self `#{u[:self_on] || 'untyped'}` guessed from the instance_eval-like call: check it"
          b = with_block(b, self_type: self_type(u))
        elsif !u[:self_eval] && !u[:forwarded] && !u[:stored] && b.self_type
          notes << "no block self type (the source yields the block itself)"
          b = with_block(b, self_type: nil)
        end
        b.equal?(mt.block) ? mt : mt.update(block: b)
      end
      mts
    end

    # The argument count every yield passes, or nil (none, several, splat).
    def yield_arity(u)
      counts = u[:yields].uniq
      counts.size == 1 ? counts.first : nil
    end

    def arity_fits?(f, n)
      return false unless f.is_a?(RBS::Types::Function)
      return true if f.rest_positionals

      req = f.required_positionals.size + f.trailing_positionals.size
      max = req + f.optional_positionals.size
      (req..max).cover?(n) || (n == 1 && req > 1) # one Array destructured by |a, b|
    end

    # A block function taking n arguments (types kept by position from
    # `old`), or `(?)` when n is unknown.
    def block_function(n, old)
      ret = old ? old.return_type : untyped
      return RBS::Types::UntypedFunction.new(return_type: ret) if n.nil?

      types = old.is_a?(RBS::Types::Function) ? old.required_positionals + old.optional_positionals + old.trailing_positionals : []
      RBS::Types::Function.empty(ret).update(required_positionals: Array.new(n) { |i| param(types[i]&.type, types[i]&.name&.to_s) })
    end

    def with_block(b, type: b.type, required: b.required, self_type: b.self_type)
      RBS::Types::Block.new(type: type, required: required, self_type: self_type, location: nil)
    end

    def self_type(u) = RBS::Parser.parse_type(u[:self_on] || "untyped")

    # `return to_enum(...) unless block_given?`: the block is required in the
    # overloads that take it, and an overload without a block returns an
    # Enumerator (of the block's argument, or untyped).
    def enumerator(mts, notes)
      without = mts.reject(&:block)
      return mts if without.any? { |mt| mt.type.respond_to?(:return_type) && mt.type.return_type.to_s.include?("Enumerator") }

      notes << "without a block the source returns an Enumerator"
      with = mts.select(&:block).map do |mt|
        f = mt.type
        next mt.update(block: with_block(mt.block, required: true)) unless f.is_a?(RBS::Types::Function)

        ret = f.return_type
        if ret.is_a?(RBS::Types::Union)
          kept = ret.types.reject { |t| t.to_s.start_with?("Enumerator", "::Enumerator") }
          ret = kept.size == 1 ? kept.first : RBS::Types::Union.new(types: kept, location: nil) unless kept.empty?
        end
        mt.update(type: f.with_return_type(ret), block: with_block(mt.block, required: true))
      end
      enums = with.filter_map do |mt|
        f = mt.type
        next unless f.is_a?(RBS::Types::Function)

        bf = mt.block.type
        elem = bf.is_a?(RBS::Types::Function) && bf.required_positionals.size == 1 ? bf.required_positionals.first.type : untyped
        ret = f.return_type
        elem, ret = untyped, untyped unless mt.type_params.empty?
        enum = RBS::Parser.parse_type("Enumerator[#{elem}, #{ret}]")
        RBS::MethodType.new(type_params: [], type: f.with_return_type(enum), block: nil, location: nil)
      end
      without + with + enums.uniq(&:to_s)
    end

    # --- nil ---

    # A body that can return nil (`return`, `return nil`, a `nil` literal,
    # `if`/`case` without `else`) gets nil in its return type unless some
    # overload already allows it.
    def nil_return(mts, src, notes)
      strong = src[:early_nil] || (src[:fixed_returns] || []).include?("nil")
      return mts unless strong || src[:implicit_nil]

      fns = mts.map(&:type).grep(RBS::Types::Function)
      return mts if fns.empty? || fns.any? { |f| Lint.nilable?(f.return_type) }

      notes << if strong then "returns nil (`return`/`nil` in the source)"
               else "nil: an `if`/`case` without `else` can end the method; drop it if the branches are exhaustive"
               end
      mts.map do |mt|
        f = mt.type
        next mt unless f.is_a?(RBS::Types::Function)
        next mt if f.return_type.to_s.start_with?("Enumerator[", "::Enumerator[")

        mt.update(type: f.with_return_type(RBS::Types::Optional.new(type: f.return_type, location: nil)))
      end
    end
  end
end
