# frozen_string_literal: true

require "rbs"

module GemTypes
  # Reads RBS text into { key => [method type strings] } plus class info.
  # Inline `# @rbs` annotations (rbs-trace's comment mode) are not read;
  # rbs-trace is used in file mode.
  class RbsReader
    Result = Struct.new(:methods, :classes, keyword_init: true)

    def self.read_files(paths, include_private: false)
      methods = Hash.new { |h, k| h[k] = [] }
      classes = {}
      paths.each do |path|
        r = read(File.read(path, encoding: "UTF-8"), path, include_private: include_private)
        r.methods.each { |k, v| methods[k] |= v }
        r.classes.each { |k, v| classes[k] ||= v }
      end
      methods.default_proc = nil # a lookup must not add keys
      Result.new(methods: methods, classes: classes)
    end

    def self.read(text, name = "(rbs)", include_private: false)
      methods = Hash.new { |h, k| h[k] = [] }
      classes = {}
      begin
        _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: text))
      rescue RBS::ParsingError => e
        warn "#{name}: #{e.message.lines.first}"
        return Result.new(methods: methods, classes: classes)
      end
      decls.each { |d| walk(d, "", methods, classes, include_private) }
      methods.default_proc = nil
      Result.new(methods: methods, classes: classes)
    end

    def self.walk(decl, ns, methods, classes, include_private = false)
      return unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      name = decl.name.to_s.delete_prefix("::")
      full = ns.empty? || decl.name.absolute? ? name : "#{ns}::#{name}"
      kind = decl.is_a?(RBS::AST::Declarations::Class) ? "class" : "module"
      sup = decl.respond_to?(:super_class) && decl.super_class ? decl.super_class.name.to_s.delete_prefix("::") : nil
      classes[full] ||= { kind: kind, super: sup }
      visibility = :public
      decl.members.each do |m|
        case m
        when RBS::AST::Members::Private then visibility = :private
        when RBS::AST::Members::Public then visibility = :public
        when RBS::AST::Members::MethodDefinition
          next if !include_private && (m.visibility || visibility) == :private && m.name != :initialize
          seps = case m.kind
                 when :singleton then ["."]
                 when :singleton_instance then ["#", "."]
                 else ["#"]
                 end
          seps.each do |sep|
            methods["#{full}#{sep}#{m.name}"] |= m.overloads.map { |o| o.method_type.to_s }
          end
        when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor, RBS::AST::Members::AttrWriter
          sep = m.kind == :singleton ? "." : "#"
          unless m.is_a?(RBS::AST::Members::AttrWriter)
            methods["#{full}#{sep}#{m.name}"] |= ["() -> #{m.type}"]
          end
          unless m.is_a?(RBS::AST::Members::AttrReader)
            methods["#{full}#{sep}#{m.name}="] |= ["(#{m.type}) -> #{m.type}"]
          end
        when RBS::AST::Members::Alias
          sep = m.kind == :singleton ? "." : "#"
          methods["#{full}#{sep}#{m.new_name}"] |= ["(alias of #{m.old_name})"]
        when RBS::AST::Declarations::Base
          walk(m, full, methods, classes, include_private)
        end
      end
    end
  end
end
