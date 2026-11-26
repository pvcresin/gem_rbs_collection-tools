# Loaded by rbs_check.sh -c. Records every method call (receiver class,
# instance or singleton, method name, and the method's owner) plus class
# ancestry, for coverage_report.rb. Uses bound Module#name so overridden
# .name methods (e.g. REXML::Functions.name) do not break it.
# Owner: "inst:M" for an instance method of class/module M (also when M is
# extended), "self:C" for a singleton method of C, "?" when unknown.
require "set"
$__calls = Set.new
# By identity: a Module subclass that forwards everything (ActiveSupport's
# DeprecatedConstantProxy) raises from #hash.
$__mods = {}.compare_by_identity
$__owners = {}.compare_by_identity
NAME = Module.instance_method(:name)
CLASS = Kernel.instance_method(:class)
SINGLETON = Module.instance_method(:singleton_class?)
owner_of = lambda do |dc|
  next "?" if dc.nil?
  if SINGLETON.bind_call(dc)
    o = (dc.attached_object rescue nil)
    n = Module === o ? NAME.bind_call(o) : nil
    n ? "self:#{n}" : "?"
  else
    n = NAME.bind_call(dc)
    n ? "inst:#{n}" : "?"
  end
end
$__tp = TracePoint.new(:call, :c_call) do |tp|
  name = tp.callee_id.to_s
  next if name.include?("RBS_TEST")
  s = tp.self
  dc = tp.defined_class
  owner = $__owners[dc] ||= (owner_of.(dc) rescue "?")
  if Module === s
    $__mods[s] = true
    $__calls << [NAME.bind_call(s) || "?", "self", name, owner]
  else
    k = CLASS.bind_call(s)
    $__mods[k] = true
    $__calls << [NAME.bind_call(k) || "?", "inst", name, owner]
  end
end
$__tp.enable
at_exit do
  $__tp.disable
  lines = $__calls.to_a.map { |a| a.join("\t") }
  $__mods.each_key do |m|
    n = NAME.bind_call(m) or next
    anc = (m.ancestors rescue []).map { |a| NAME.bind_call(a) }.compact
    sanc = (m.singleton_class.ancestors rescue []).map { |a| a.singleton_class? ? ((a.attached_object rescue nil).then { |o| Module === o ? NAME.bind_call(o) : nil }) : NAME.bind_call(a) }.compact rescue []
    lines << ["ANC", n, (anc | sanc).join(",")].join("\t")
  end
  # Appended by every process of the run; rbs_check.sh clears it first.
  File.open(ENV.fetch("TRACE_OUT"), "a") { |f| f.flock(File::LOCK_EX); f.puts(lines) } unless lines.empty?
end
