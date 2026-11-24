# Lists methods declared in an RBS file that were never called during a run.
#
# Usage: ruby coverage_report.rb <file.rbs> <calls file from rbs_check.sh -c>
#   SHOW_ALL=1  list every declared method instead of the uncalled ones
#
# Declarations come from the RBS AST (def, alias, attr_*), so aliases count.
# A call on a subclass covers the method declared on its ancestor.
# An instance #initialize counts as covered when .new was called.
require "rbs"; require "set"
file, trace = ARGV
_, _, decls = RBS::Parser.parse_signature(File.read(file))
declared = []
walk = lambda do |decl, ns|
  case decl
  when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
    name = decl.name.to_s.delete_prefix("::")
    full = (ns.empty? || decl.name.absolute?) ? name : "#{ns}::#{name}"
    vis = :public
    decl.members.each do |m|
      case m
      when RBS::AST::Members::Private then vis = :private
      when RBS::AST::Members::Public then vis = :public
      when RBS::AST::Members::MethodDefinition
        v = m.visibility || vis
        kinds = m.kind == :singleton_instance ? [:inst, :self] : [m.kind == :singleton ? :self : :inst]
        kinds.each { |k| declared << [full, k, m.name.to_s, v] }
      when RBS::AST::Members::Alias
        declared << [full, m.kind == :singleton ? :self : :inst, m.new_name.to_s, vis]
      when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor, RBS::AST::Members::AttrWriter
        k = m.kind == :singleton ? :self : :inst
        declared << [full, k, m.name.to_s, vis] unless m.is_a?(RBS::AST::Members::AttrWriter)
        declared << [full, k, "#{m.name}=", vis] unless m.is_a?(RBS::AST::Members::AttrReader)
      when RBS::AST::Declarations::Base then walk.(m, full)
      end
    end
  end
end
decls.each { |d| walk.(d, "") }
calls = Hash.new { |h, k| h[k] = Set.new }
anc = Hash.new { |h, k| h[k] = [k] }
File.foreach(trace) do |l|
  a, b, c = l.chomp.split("\t")
  if a == "ANC" then anc[b] = (c || "").split(",") | [b]
  else calls[[b.to_sym, c]] << a end
end
sub = ->(c, cls) { c == cls || anc[c].include?(cls) }
missing = declared.reject do |cls, k, m, v|
  mm = (k == :self && m == "initialize") ? m : m
  calls[[k, mm]].any? { |c| sub.(c, cls) } ||
    (k == :inst && m == "initialize" && calls[[:self, "new"]].any? { |c| sub.(c, cls) })
end
STDERR.puts "declared=#{declared.size} missing=#{missing.size}"
(ENV["SHOW_ALL"] ? declared : missing).each { |cls, k, m, v| puts "#{cls}#{k == :self ? '.' : '#'}#{m}#{v == :private ? ' (private)' : ''}" }
