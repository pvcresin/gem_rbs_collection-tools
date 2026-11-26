# Records the argument, block and return types that actually flow through a
# gem's methods while some Ruby code runs (typically the gem's own test
# suite), and prints them in an RBS-like summary. Use it as evidence when
# writing signatures; it shows only what the run exercised.
#
# Usually run through `gem-types collect`. By hand:
#        RUBYOPT="-r/path/to/hooks/observe.rb" \
#        OBSERVE_NS="Timecop,Timecop::*" OBSERVE_OUT=/tmp/timecop.types \
#        bundle exec rake test
#   OBSERVE_NS   comma list; "Foo" matches Foo only, "Foo::*" also nested
#   OBSERVE_OUT  output file (written at exit); OBSERVE_OUT.json is the
#                machine-readable form used by `gem-types draft`
#   OBSERVE_DIR  instead of OBSERVE_OUT: write observe-<pid>.types(.json)
#                there, so a test run with many processes keeps them all
#   OBSERVE_PRIVATE=1 to include private/protected methods
#
# Output, per method (sorted): a summary line, then (when there is more than
# one) each distinct call shape and how it ended:
#   Foo#bar: (x: Integer | String, ?y: nil) block=no/yes -> String | raise ArgumentError   # 12 calls
#       (Integer, nil) -> String
#       (String, nil) {} -> raise ArgumentError
# A shape that only ever raises is usually a negative test: the RBS can
# leave it out on purpose.
# Remember: tests also call methods with invalid input on purpose; check
# where an odd type came from before putting it in the RBS.
# RUBYOPT also reaches the `bundle` command itself; only hook real programs.
return if %w[bundle bundler].include?(File.basename($PROGRAM_NAME))
require "set"
module ObserveTypes
  NAME = Module.instance_method(:name)
  CLASS = Kernel.instance_method(:class)
  PATTERNS = ENV.fetch("OBSERVE_NS").split(",").map(&:strip)
  INCLUDE_PRIVATE = ENV["OBSERVE_PRIVATE"] == "1"
  LIB = ENV.fetch("OBSERVE_LIB", "").split(":").reject(&:empty?).map { |l| File.join(File.expand_path(l), "") }
  UNSET = Object.new.freeze
  @match_cache = {}
  @ancestors = {}
  @data = Hash.new do |h, k|
    h[k] = { params: {}, ret: Set.new, block: Set.new, n: 0, shapes: Hash.new { |hh, kk| hh[kk] = Set.new },
             ok: { params: {}, ret: Set.new, block: Set.new, n: 0, ret_nb: Set.new }, kinds: {},
             self_ret: [0, 0], passthrough: [0, 0], blk_args: [], blk_ret: Set.new, blk_self: Set.new }
  end
  class << self
    attr_reader :data, :ancestors
    def type_of(v)
      # Subclasses of Array/Hash (e.g. a TokenArray < Array) keep their name.
      k = CLASS.bind_call(v)
      return type_of_shallow(v) if (Array === v && k != Array) || (Hash === v && k != Hash)

      case v
      when nil then "nil"
      when true, false then "bool"
      when Array then "Array[#{v.first(5).map { |e| type_of_shallow(e) }.uniq.join(' | ').then { |s| s.empty? ? 'untyped' : s }}]"
      when Hash then
        ks = v.keys.first(5).map { |e| type_of_shallow(e) }.uniq.join(" | ")
        vs = v.values.first(5).map { |e| type_of_shallow(e) }.uniq.join(" | ")
        v.empty? ? "Hash[untyped, untyped]" : "Hash[#{ks}, #{vs}]"
      else type_of_shallow(v)
      end
    end
    def type_of_shallow(v)
      # equal?, not ==: DSL objects (e.g. XPath::Expression) override ==.
      return "nil" if nil.equal?(v)
      return "bool" if true.equal?(v) || false.equal?(v)
      k = CLASS.bind_call(v)
      if Module === v then "singleton(#{NAME.bind_call(v) || 'anon'})"
      else
        name = NAME.bind_call(k)
        if name
          @ancestors[name] ||= k.ancestors.filter_map { |a| NAME.bind_call(a) }.first(20)
          name
        else
          (k.ancestors.map { |a| NAME.bind_call(a) }.compact.first || "anon") + "(anon)"
        end
      end
    rescue StandardError
      "?"
    end
    def immediate?(v) = nil.equal?(v) || true.equal?(v) || false.equal?(v) || Integer === v || Symbol === v || Float === v
    def owner_name(tp)
      dc = tp.defined_class
      if dc.singleton_class?
        o = dc.attached_object rescue nil
        n = o.is_a?(Module) ? NAME.bind_call(o) : nil
        n && [n, "."]
      else
        n = NAME.bind_call(dc)
        n && [n, "#"]
      end
    end
    def match?(name)
      @match_cache.fetch(name) do
        @match_cache[name] = PATTERNS.any? { |p| p.end_with?("::*") ? (name == p[0..-4] || name.start_with?(p[0..-2])) : name == p }
      end
    end
  end
end
module ObserveTypes
  # Blocks defined in Ruby's standard library, installed gems or the VM
  # (Timeout, Tempfile, rspec-mocks...) are neither the library's nor the
  # caller's: ignore them.
  FOREIGN = ([RbConfig::CONFIG["rubylibdir"]] +
             Gem.path.flat_map { |g| [File.join(g, "gems", ""), File.join(g, "bundler", "gems", "")] })
            .compact.map { |d| File.join(File.expand_path(d), "") }.uniq
  @bmethod = {}
  # Per fiber (an Enumerator#next runs in its own fiber): the traced frames,
  # and the library blocks running for them (see :b_call).
  @stacks = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap.new : {}.compare_by_identity
  @lib_blocks = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap.new : {}.compare_by_identity
  class << self
    def stack = (@stacks[Fiber.current] ||= [])
    def lib_blocks = (@lib_blocks[Fiber.current] ||= [])
    def lib?(path) = LIB.any? { |l| path.start_with?(l) }
    def foreign?(path) = path.start_with?("<internal:") || FOREIGN.any? { |l| path.start_with?(l) }

    # A method made by define_method: its binding is the block's, so
    # block_given? there reads the block of the method that defined it.
    def bmethod?(tp)
      @bmethod.fetch([tp.defined_class, tp.method_id]) do |k|
        iseq = (RubyVM::InstructionSequence.of(tp.defined_class.instance_method(tp.method_id)) rescue nil)
        @bmethod[k] = iseq ? iseq.label.start_with?("block ") : false
      end
    end

    # An exception unwinds every frame of this fiber until it is rescued
    # (calls made meanwhile, e.g. from ensure, start unmarked).
    def mark(exc) = stack.each { |f| f[:exc] = exc }
    def clear(kind = nil) = stack.each { |f| f[:exc] = nil if kind.nil? || f[:exc].equal?(kind) }
    def reset!
      data.clear
      @stacks = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap.new : {}.compare_by_identity
      @lib_blocks = defined?(ObjectSpace::WeakKeyMap) ? ObjectSpace::WeakKeyMap.new : {}.compare_by_identity
    end

    # Whether a caller block running now belongs to `frame` (stack[i]).
    # A frame called by the library itself got either a block passed down
    # (`inner(&blk)`, the caller's) or one of the library's own; only the
    # first counts.
    def owns_block?(st, i)
      frame = st[i]
      return true unless frame[:from_lib]
      return false if frame[:foreign_blocks].positive?

      if frame[:proc]
        outer = st[0...i].reverse.find { |f| f[:blk] == "yes" && f[:proc] }
        return outer ? outer[:proc].equal?(frame[:proc]) : true
      end
      true
    end
  end

  THROW = Object.new.freeze
  # throw unwinds frames without an exception: mark them like one, and
  # clear the mark once the catch is done.
  module ThrowHook
    private

    def throw(*args)
      ObserveTypes.mark(ObserveTypes::THROW)
      super
    end

    def catch(*args, &blk)
      super
    ensure
      ObserveTypes.clear(ObserveTypes::THROW)
    end
  end
  ::Kernel.prepend(ThrowHook)

  # A forked child starts with the parent's data; it writes only its own.
  module ForkHook
    def _fork
      pid = super
      ObserveTypes.reset! if pid.zero?
      pid
    end
  end
  ::Process.singleton_class.prepend(ForkHook) if ::Process.respond_to?(:_fork)
end
ObserveTypes::TP = TracePoint.new(:call, :return, :raise, :rescue, :b_call, :b_return) do |tp|
  case tp.event
  when :raise then ObserveTypes.mark(tp.raised_exception); next
  when :rescue then ObserveTypes.clear; next
  when :b_call, :b_return
    path = tp.path
    st = ObserveTypes.stack
    if ObserveTypes.lib?(path)
      # A library block. When a frame called from the library runs one that
      # it did not define itself (its caller's literal block), a caller
      # block run meanwhile is not this frame's block.
      lb = ObserveTypes.lib_blocks
      if tp.event == :b_call
        top = st.last
        foreign = nil
        if top && top[:from_lib] && top[:blk] == "yes" && !top[:proc]
          b = tp.binding
          own = (b.eval("__method__") rescue nil) == top[:mid] && b.receiver.equal?(top[:self])
          (foreign = top)[:foreign_blocks] += 1 unless own
        end
        lb << foreign
      elsif (f = lb.pop)
        f[:foreign_blocks] -= 1
      end
      next
    end
    next if ObserveTypes.foreign?(path)

    # A block from outside the library (the caller's) runs while methods we
    # trace are on the stack: attribute it to the top frames that were given
    # it (a block passed down with &block reaches several of them).
    # Record its arguments, its self and what it returns.
    top = st.last
    next unless top && top[:blk] == "yes" && path != top[:path]

    (st.size - 1).downto(0) do |i|
      frame = st[i]
      break unless frame[:blk] == "yes"
      next unless ObserveTypes.owns_block?(st, i)

      if tp.event == :b_call
        if frame[:bdepth].zero?
          d = ObserveTypes.data[frame[:key]]
          b = tp.binding
          pos = 0
          tp.parameters.each do |kind, pname|
            # Only positional parameters: keywords are not block arguments.
            break if kind == :rest
            next unless %i[req opt].include?(kind)

            idx = pos
            pos += 1
            next unless pname

            v = (b.local_variable_get(pname) rescue next)
            (d[:blk_args][idx] ||= Set.new) << ObserveTypes.type_of(v)
          end
          d[:blk_self] << (tp.self.equal?(frame[:self]) ? "receiver" : "caller")
        end
        frame[:bdepth] += 1
      else
        next if frame[:bdepth].zero?

        frame[:bdepth] -= 1
        if frame[:bdepth].zero?
          frame[:blk_val] = tp.return_value
          ObserveTypes.data[frame[:key]][:blk_ret] << ObserveTypes.type_of(tp.return_value)
        end
      end
    end
    next
  end
  st = ObserveTypes.stack
  if tp.event == :return
    top = st.last
    next unless top && top[:mid] == tp.method_id && top[:callee] == (tp.callee_id || tp.method_id) && top[:dc].equal?(tp.defined_class)

    frame = st.pop
    key = frame[:key]
    d = ObserveTypes.data[key]
    # While an exception (or throw) unwinds the method, return_value is nil.
    rv = tp.return_value
    e = frame[:exc]
    # Limitation: an exception rescued inside C code fires no :rescue event,
    # so its mark can outlive it (Ruby 3.3's loop rescues StopIteration in
    # Ruby and is fine). $! cannot tell: it is nil in TracePoint hooks.
    outcome = if e && nil.equal?(rv)
                e.equal?(ObserveTypes::THROW) ? "throw" : "raise #{e.class}"
              else
                ObserveTypes.type_of(rv)
              end
    d[:ret] << outcome
    unless outcome.start_with?("raise ") || outcome == "throw"
      ok = d[:ok]; ok[:n] += 1; ok[:ret] << outcome; ok[:block] << frame[:blk]
      ok[:ret_nb] << outcome if frame[:blk] == "no"
      frame[:params].each { |l, ts| (ok[:params][l] ||= Set.new).merge(ts) }
      d[:self_ret][1] += 1
      d[:self_ret][0] += 1 if !ObserveTypes.immediate?(rv) && rv.equal?(frame[:self])
      unless frame[:blk_val].equal?(ObserveTypes::UNSET)
        bv = frame[:blk_val]
        d[:passthrough][1] += 1
        d[:passthrough][0] += 1 if ObserveTypes.immediate?(bv) ? bv == rv : bv.equal?(rv)
      end
    end
    d[:shapes][frame[:shape]] << outcome if d[:shapes].size < 30 || d[:shapes].key?(frame[:shape])
    next
  end
  owner = ObserveTypes.owner_name(tp) rescue nil
  next unless owner && ObserveTypes.match?(owner[0])

  dc = tp.defined_class
  mid = tp.method_id
  callee = tp.callee_id || mid
  name = mid
  unless ObserveTypes::INCLUDE_PRIVATE || mid == :initialize
    # Visibility of the name it was called by: a public alias of a private
    # method is public (and is recorded under the alias).
    next if dc.private_method_defined?(callee) || dc.protected_method_defined?(callee)

    name = callee if callee != mid && (dc.private_method_defined?(mid) || dc.protected_method_defined?(mid))
  end
  key = "#{owner[0]}#{owner[1]}#{name}"
  d = ObserveTypes.data[key]; d[:n] += 1
  b = tp.binding
  shape = []
  call_params = {}
  blk_param = nil
  tp.parameters.each do |kind, pname|
    if kind == :block
      blk_param = pname && pname != :& ? pname : :anonymous
      next
    end
    # Anonymous `*`, `**` and `...`: their values cannot be read; keep the
    # parameter so drafts do not lose it.
    if pname.nil? || %i[* **].include?(pname)
      next unless %i[rest keyrest].include?(kind)

      label = kind == :rest ? "*" : "**"
      (d[:params][label] ||= Set.new) << "untyped"
      d[:kinds][label] = [kind.to_s, ""]
      call_params[label] = ["untyped"]
      next
    end
    v = (b.local_variable_get(pname) rescue next)
    label = case kind
            when :opt then "?#{pname}"
            when :rest then "*#{pname}"
            when :key then "?#{pname}:"
            when :keyreq then "#{pname}:"
            when :keyrest then "**#{pname}"
            else pname.to_s
            end
    t = case kind
        when :rest then v.map { |e| ObserveTypes.type_of(e) }
        when :keyrest then v.values.map { |e| ObserveTypes.type_of(e) }
        else [ObserveTypes.type_of(v)]
        end
    (d[:params][label] ||= Set.new).merge(t.empty? ? ["(none)"] : t)
    d[:kinds][label] = [kind.to_s, pname.to_s]
    call_params[label] = t
    shape << (kind == :rest ? t.join(", ") : "#{label =~ /:$/ ? label + ' ' : ''}#{t.join(', ')}") unless t.empty?
  end
  # The block: from the & parameter when there is one; a define_method
  # method without one cannot take a block (block_given? there would read
  # the block of the method that called define_method).
  proc_obj = nil
  given = if blk_param && blk_param != :anonymous
            proc_obj = (b.local_variable_get(blk_param) rescue nil)
            !proc_obj.nil?
          elsif ObserveTypes.bmethod?(tp)
            false
          else
            (b.eval("block_given?") rescue false)
          end
  blk = given ? "yes" : "no"
  d[:block] << blk
  caller_path = caller_locations(2, 1)&.first&.path.to_s
  st << { key: key, mid: mid, callee: callee, dc: dc,
          shape: "(#{shape.join(', ')})#{blk == 'yes' ? ' {}' : ''}", params: call_params, blk: blk,
          self: tp.self, path: tp.path, bdepth: 0, blk_val: ObserveTypes::UNSET, exc: nil,
          from_lib: ObserveTypes.lib?(caller_path), proc: proc_obj, foreign_blocks: 0 }
end
ObserveTypes::TP.enable
at_exit do
  ObserveTypes::TP.disable
  lines = ObserveTypes.data.sort.map do |key, d|
    ps = d[:params].map { |label, ts| "#{label}: #{ts.to_a.sort.join(' | ')}" }.join(", ")
    notes = []
    notes << "returns self" if d[:self_ret][1].positive? && d[:self_ret][0] == d[:self_ret][1]
    notes << "returns the block's value" if d[:passthrough][1].positive? && d[:passthrough][0] == d[:passthrough][1]
    notes << "block args (#{d[:blk_args].map { |s| s ? s.to_a.sort.join(' | ') : 'untyped' }.join(', ')})" unless d[:blk_args].empty?
    notes << "block self = receiver" if d[:blk_self] == Set["receiver"]
    head = "#{key}: (#{ps}) block=#{d[:block].to_a.sort.join('/')} -> #{d[:ret].to_a.sort.join(' | ')}   # #{d[:n]} calls" +
           (notes.empty? ? "" : "; #{notes.join('; ')}")
    shapes = d[:shapes].sort.map { |sh, outs| "    #{sh} -> #{outs.to_a.sort.join(' | ')}" }
    ([head] + (shapes.size > 1 ? shapes : [])).join("\n")
  end
  out = ENV["OBSERVE_OUT"] || File.join(ENV.fetch("OBSERVE_DIR"), "observe-#{Process.pid}.types")
  File.write(out, lines.join("\n") + "\n")
  # Machine-readable form for `gem-types draft`: only calls that returned normally.
  require "json"
  json = ObserveTypes.data.to_h do |key, d|
    [key, { "calls" => d[:n], "ok_calls" => d[:ok][:n], "kinds" => d[:kinds],
            "params" => d[:ok][:params].transform_values { |v| v.to_a.sort },
            "block" => d[:ok][:block].to_a.sort, "returns" => d[:ok][:ret].to_a.sort, "returns_without_block" => d[:ok][:ret_nb].to_a.sort,
            "raises" => d[:ret].select { |r| r.start_with?("raise ") }.sort,
            "self_returns" => d[:self_ret], "block_passthrough" => d[:passthrough],
            "block_args" => d[:blk_args].map { |s| s ? s.to_a.sort : [] },
            "block_returns" => d[:blk_ret].to_a.sort, "block_self" => d[:blk_self].to_a.sort }]
  end
  json["__ancestors__"] = ObserveTypes.ancestors
  File.write(out + ".json", JSON.pretty_generate(json))
end
