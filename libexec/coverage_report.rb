# Lists methods declared in an RBS file that were never called during a run.
#
# Usage: ruby coverage_report.rb <file.rbs> <calls file from rbs_check.sh -c>
#   SHOW_ALL=1  list every declared method instead of the uncalled ones
#
# Declarations come from the RBS AST (def, alias, attr_*), so aliases count.
# A call counts for a declaration only when the method that ran is the
# declaring class's own (the owner trace_calls.rb records): a call on a
# subclass that inherits the method counts, one that overrides it does not,
# and a module's instance method counts when the module is included or
# extended, not when a same-named method of Module (to_s, name, ...) is
# called on the module itself. The instance copy of `def self?.m`
# (module_function) counts when the singleton one was called.
# An instance #initialize also counts as covered when .new was called on
# the class itself. Calls files without owners (older traces) fall back to
# matching by receiver class and ancestry.
require "rbs"; require "set"
file, trace = ARGV
_, _, decls = RBS::Parser.parse_signature(File.read(file))
declared = []
modules = Set.new
walk = lambda do |decl, ns|
  case decl
  when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
    name = decl.name.to_s.delete_prefix("::")
    full = (ns.empty? || decl.name.absolute?) ? name : "#{ns}::#{name}"
    modules << full if decl.is_a?(RBS::AST::Declarations::Module)
    vis = :public
    decl.members.each do |m|
      case m
      when RBS::AST::Members::Private then vis = :private
      when RBS::AST::Members::Public then vis = :public
      when RBS::AST::Members::MethodDefinition
        v = m.visibility || vis
        if m.kind == :singleton_instance
          declared << [full, :inst, m.name.to_s, v, :pair]
          declared << [full, :self, m.name.to_s, v, nil]
        else
          declared << [full, m.kind == :singleton ? :self : :inst, m.name.to_s, v, nil]
        end
      when RBS::AST::Members::Alias
        declared << [full, m.kind == :singleton ? :self : :inst, m.new_name.to_s, vis, nil]
      when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor, RBS::AST::Members::AttrWriter
        k = m.kind == :singleton ? :self : :inst
        v = m.visibility || vis
        declared << [full, k, m.name.to_s, v, nil] unless m.is_a?(RBS::AST::Members::AttrWriter)
        declared << [full, k, "#{m.name}=", v, nil] unless m.is_a?(RBS::AST::Members::AttrReader)
      when RBS::AST::Declarations::Base then walk.(m, full)
      end
    end
  end
end
decls.each { |d| walk.(d, "") }
# [kind, method] => { receiver class => Set of owners (nil: not recorded) }
calls = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Set.new } }
anc = Hash.new { |h, k| h[k] = [k] }
File.foreach(trace) do |l|
  a, b, c, d = l.chomp.split("\t")
  if a == "ANC" then anc[b] = (c || "").split(",") | [b]
  else calls[[b.to_sym, c]][a] << d end
end
sub = ->(c, cls) { c == cls || anc[c].include?(cls) }
# Was `cls`'s own method `m` (instance or singleton) run?
CORE = %w[BasicObject Object Kernel Module Class].freeze
ran = lambda do |cls, k, m|
  calls[[:inst, m]].any? { |recv, owners| owners.any? { |o| o.nil? ? k == :inst && sub.(recv, cls) : o == "#{k}:#{cls}" } } ||
    calls[[:self, m]].any? do |recv, owners|
      owners.any? do |o|
        if o.nil?
          # Older trace: a singleton call on cls or a subclass, or a call on
          # something that extends the module cls.
          sub.(recv, cls) && (k == :self || modules.include?(cls))
        elsif o == "#{k}:#{cls}"
          true
        else
          # `def self.m` implemented by a module that cls extends.
          k == :self && recv == cls && o.start_with?("inst:") && !CORE.include?(o.delete_prefix("inst:"))
        end
      end
    end
end
missing = declared.reject do |cls, k, m, _v, pair|
  ran.(cls, k, m) ||
    (pair && ran.(cls, :self, m)) ||
    (k == :inst && m == "initialize" && calls[[:self, "new"]].key?(cls))
end
STDERR.puts "declared=#{declared.size} missing=#{missing.size}"
(ENV["SHOW_ALL"] ? declared : missing).each { |cls, k, m, v| puts "#{cls}#{k == :self ? '.' : '#'}#{m}#{v == :private ? ' (private)' : ''}" }
