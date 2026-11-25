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
  @stack = Hash.new { |h, k| h[k] = [] }
  class << self
    attr_reader :data, :stack, :ancestors
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
# An exception being propagated (raised and not yet rescued), per thread.
ObserveTypes::PENDING = {}
ObserveTypes::TP = TracePoint.new(:call, :return, :raise, :rescue, :b_call, :b_return) do |tp|
  case tp.event
  when :raise then ObserveTypes::PENDING[Thread.current] = tp.raised_exception; next
  when :rescue then ObserveTypes::PENDING.delete(Thread.current); next
  when :b_call, :b_return
    # A block from outside the library (the caller's) runs while methods we
    # trace are on the stack: attribute it to the top frames that were given
    # a block (a block passed down with &block reaches several of them).
    # Record its arguments, its self and what it returns.
    next if ObserveTypes::LIB.any? { |l| tp.path.start_with?(l) }
    st = ObserveTypes.stack[Thread.current]
    top = st.last
    next unless top && top[:blk] == "yes" && tp.path != top[:path]
    st.reverse_each do |frame|
      break unless frame[:blk] == "yes"
      if tp.event == :b_call
        if frame[:bdepth].zero?
          d = ObserveTypes.data[frame[:key]]
          b = tp.binding
          tp.parameters.each_with_index do |(_, pname), i|
            next unless pname && !pname.to_s.start_with?("*", "&")
            v = (b.local_variable_get(pname) rescue next)
            (d[:blk_args][i] ||= Set.new) << ObserveTypes.type_of(v)
          end
          d[:blk_self] << (tp.self.equal?(frame[:self]) ? "receiver" : "caller")
        end
        frame[:bdepth] += 1
      else
        frame[:bdepth] -= 1
        if frame[:bdepth].zero?
          frame[:blk_val] = tp.return_value
          ObserveTypes.data[frame[:key]][:blk_ret] << ObserveTypes.type_of(tp.return_value)
        end
      end
    end
    next
  end
  owner = ObserveTypes.owner_name(tp) rescue nil
  next unless owner && ObserveTypes.match?(owner[0])
  key = "#{owner[0]}#{owner[1]}#{tp.method_id}"
  st = ObserveTypes.stack[Thread.current]
  if tp.event == :call
    unless ObserveTypes::INCLUDE_PRIVATE || tp.method_id == :initialize
      vis_owner = tp.defined_class
      next if vis_owner.private_method_defined?(tp.method_id) || vis_owner.protected_method_defined?(tp.method_id)
    end
    d = ObserveTypes.data[key]; d[:n] += 1
    b = tp.binding
    shape = []
    call_params = {}
    tp.parameters.each do |kind, pname|
      next unless pname && !pname.to_s.start_with?("*", "&")
      next if kind == :block
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
    blk = (b.eval("block_given?") rescue nil) ? "yes" : "no"
    d[:block] << blk
    st << { key: key, shape: "(#{shape.join(', ')})#{blk == 'yes' ? ' {}' : ''}", params: call_params, blk: blk,
            self: tp.self, path: tp.path, bdepth: 0, blk_val: ObserveTypes::UNSET }
  else
    next unless st.last && st.last[:key] == key
    frame = st.pop
    d = ObserveTypes.data[key]
    # While an exception unwinds the method, return_value is nil. The
    # pending exception is cleared only by a :rescue event, so calls made
    # while it propagates (rescue matching, ensure) do not hide it.
    e = ObserveTypes::PENDING[Thread.current]
    rv = tp.return_value
    outcome = e && nil.equal?(rv) ? "raise #{e.class}" : ObserveTypes.type_of(rv)
    d[:ret] << outcome
    unless outcome.start_with?("raise ")
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
  end
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
