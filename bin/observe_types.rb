# Records the argument, block and return types that actually flow through a
# gem's methods while some Ruby code runs (typically the gem's own test
# suite), and prints them in an RBS-like summary. Use it as evidence when
# writing signatures; it shows only what the run exercised.
#
# Usage: RUBYOPT="-r/path/to/observe_types.rb" \
#        OBSERVE_NS="Timecop,Timecop::*" OBSERVE_OUT=/tmp/timecop.types \
#        bundle exec rake test
#   OBSERVE_NS   comma list; "Foo" matches Foo only, "Foo::*" also nested
#   OBSERVE_OUT  output file (written at exit); OBSERVE_OUT.json is the
#                machine-readable form used by draft_rbs.rb
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
require "set"
module ObserveTypes
  NAME = Module.instance_method(:name)
  CLASS = Kernel.instance_method(:class)
  PATTERNS = ENV.fetch("OBSERVE_NS").split(",").map(&:strip)
  INCLUDE_PRIVATE = ENV["OBSERVE_PRIVATE"] == "1"
  @match_cache = {}
  @data = Hash.new { |h, k| h[k] = { params: {}, ret: Set.new, block: Set.new, n: 0, shapes: Hash.new { |hh, kk| hh[kk] = Set.new }, ok: { params: {}, ret: Set.new, block: Set.new, n: 0 }, kinds: {} } }
  @stack = Hash.new { |h, k| h[k] = [] }
  class << self
    attr_reader :data, :stack
    def type_of(v)
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
      return "nil" if v.nil?
      return "bool" if v == true || v == false
      k = CLASS.bind_call(v)
      if Module === v then "singleton(#{NAME.bind_call(v) || 'anon'})"
      else NAME.bind_call(k) || (k.ancestors.map { |a| NAME.bind_call(a) }.compact.first || "anon") + "(anon)"
      end
    rescue StandardError
      "?"
    end
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
ObserveTypes::TP = TracePoint.new(:call, :return, :raise, :rescue) do |tp|
  case tp.event
  when :raise then ObserveTypes::PENDING[Thread.current] = tp.raised_exception; next
  when :rescue then ObserveTypes::PENDING.delete(Thread.current); next
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
    ObserveTypes::PENDING.delete(Thread.current)
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
    st << [key, "(#{shape.join(', ')})#{blk == 'yes' ? ' {}' : ''}", call_params, blk]
  else
    next unless st.last && st.last[0] == key
    _, shape, call_params, blk = st.pop
    d = ObserveTypes.data[key]
    # While an exception unwinds the method, return_value is nil.
    e = ObserveTypes::PENDING[Thread.current]
    outcome = e && tp.return_value.nil? ? "raise #{e.class}" : ObserveTypes.type_of(tp.return_value)
    d[:ret] << outcome
    unless outcome.start_with?("raise ")
      ok = d[:ok]; ok[:n] += 1; ok[:ret] << outcome; ok[:block] << blk
      call_params.each { |l, ts| (ok[:params][l] ||= Set.new).merge(ts) }
    end
    d[:shapes][shape] << outcome if d[:shapes].size < 30 || d[:shapes].key?(shape)
  end
end
ObserveTypes::TP.enable
at_exit do
  ObserveTypes::TP.disable
  lines = ObserveTypes.data.sort.map do |key, d|
    ps = d[:params].map { |label, ts| "#{label}: #{ts.to_a.sort.join(' | ')}" }.join(", ")
    head = "#{key}: (#{ps}) block=#{d[:block].to_a.sort.join('/')} -> #{d[:ret].to_a.sort.join(' | ')}   # #{d[:n]} calls"
    shapes = d[:shapes].sort.map { |sh, outs| "    #{sh} -> #{outs.to_a.sort.join(' | ')}" }
    ([head] + (shapes.size > 1 ? shapes : [])).join("\n")
  end
  File.write(ENV.fetch("OBSERVE_OUT"), lines.join("\n") + "\n")
  # Machine-readable form for draft_rbs.rb: only calls that returned normally.
  require "json"
  json = ObserveTypes.data.to_h do |key, d|
    [key, { "calls" => d[:n], "ok_calls" => d[:ok][:n], "kinds" => d[:kinds],
            "params" => d[:ok][:params].transform_values { |v| v.to_a.sort },
            "block" => d[:ok][:block].to_a.sort, "returns" => d[:ok][:ret].to_a.sort,
            "raises" => d[:ret].select { |r| r.start_with?("raise ") }.sort }]
  end
  File.write(ENV.fetch("OBSERVE_OUT") + ".json", JSON.pretty_generate(json))
end
