# Loaded by rbs_check.sh -c. Records every method call (receiver class,
# instance or singleton, method name) plus class ancestry, for
# coverage_report.rb. Uses bound Module#name so overridden .name methods
# (e.g. REXML::Functions.name) do not break it.
require "set"
$__calls = Set.new
$__mods = Set.new
NAME = Module.instance_method(:name)
CLASS = Kernel.instance_method(:class)
$__tp = TracePoint.new(:call, :c_call) do |tp|
  name = tp.callee_id.to_s
  next if name.include?("RBS_TEST")
  s = tp.self
  if Module === s
    $__mods << s
    $__calls << [NAME.bind_call(s) || "?", "self", name]
  else
    k = CLASS.bind_call(s)
    $__mods << k
    $__calls << [NAME.bind_call(k) || "?", "inst", name]
  end
end
$__tp.enable
at_exit do
  $__tp.disable
  lines = $__calls.to_a.map { |a| a.join("\t") }
  $__mods.each do |m|
    n = NAME.bind_call(m) or next
    anc = (m.ancestors rescue []).map { |a| NAME.bind_call(a) }.compact
    sanc = (m.singleton_class.ancestors rescue []).map { |a| a.singleton_class? ? ((a.attached_object rescue nil).then { |o| Module === o ? NAME.bind_call(o) : nil }) : NAME.bind_call(a) }.compact rescue []
    lines << ["ANC", n, (anc | sanc).join(",")].join("\t")
  end
  # Appended by every process of the run; rbs_check.sh clears it first.
  File.open(ENV.fetch("TRACE_OUT"), "a") { |f| f.flock(File::LOCK_EX); f.puts(lines) } unless lines.empty?
end
