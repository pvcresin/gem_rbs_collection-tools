# frozen_string_literal: true

require "rbs"

module GemTypes
  # Reads RBS text into { key => [method type strings] } plus class info.
  # Inline `# @rbs` annotations (rbs-trace's comment mode) are not read;
  # rbs-trace is used in file mode.
  #
  # A method declared with `| ...` (overloading an existing definition) ends
  # its list with "...", so that joining the list with " | " gives the
  # declaration back.
  class RbsReader
    Result = Struct.new(:methods, :classes, keyword_init: true)

    # Lines blanked out to get past syntax errors before giving up on a text.
    MAX_SKIPPED_LINES = 50

    def self.read_files(paths, include_private: false)
      methods = Hash.new { |h, k| h[k] = [] }
      classes = {}
      paths.each do |path|
        r = read(File.read(path, encoding: "UTF-8"), path, include_private: include_private)
        r.methods.each { |k, v| methods[k] = dots_last(methods[k] | v) }
        r.classes.each { |k, v| merge_class(classes, k, v) }
      end
      methods.default_proc = nil # a lookup must not add keys
      Result.new(methods: methods, classes: classes)
    end

    # RBS files under a directory (or the one file given), without the
    # `_test` directories, which hold the collection's tests, not the gem's
    # signatures.
    def self.sig_files(path)
      return [path] unless File.directory?(path)

      # Like `rbs collection`: directories starting with "_" (_test, _scripts)
      # are not part of the signatures.
      Dir[File.join(path, "**", "*.rbs")].reject do |f|
        File.dirname(f).delete_prefix(path).split(File::SEPARATOR).any? { |part| part.start_with?("_") }
      end.sort
    end

    def self.read(text, name = "(rbs)", include_private: false)
      methods = Hash.new { |h, k| h[k] = [] }
      classes = {}
      text = text.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub("?") unless text.valid_encoding?
      decls = parse_tolerantly(text, name) or return Result.new(methods: methods, classes: classes)
      decls.each { |d| walk(d, "", methods, classes, include_private) }
      methods.default_proc = nil
      Result.new(methods: methods, classes: classes)
    end

    # Generated RBS (TypeProf, tyda, ...) sometimes has a line RBS does not
    # parse; one such line must not lose the whole file. Blank the offending
    # line and try again, up to MAX_SKIPPED_LINES times.
    def self.parse_tolerantly(text, name)
      # Tool output can contain NUL bytes, which the parser rejects outright.
      lines = text.delete("\0").lines
      skipped = 0
      loop do
        _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: name, content: lines.join))
        return decls
      rescue ArgumentError => e
        warn "#{name}: #{e.message} (giving up on this file)"
        return nil
      rescue RBS::ParsingError => e
        line = e.location&.start_line
        idx = line && line - 1
        if idx.nil? || idx >= lines.size || lines[idx].strip.empty? || skipped >= MAX_SKIPPED_LINES
          warn "#{name}: #{e.message.lines.first.chomp} (giving up on this file)"
          return nil
        end
        warn "#{name}: #{e.message.lines.first.chomp} (line #{line} skipped)"
        lines[idx] = "\n"
        skipped += 1
      end
    end

    def self.dots_last(list) = list.include?("...") ? (list - ["..."]) + ["..."] : list

    # The first declaration gives the kind; a superclass may come from a
    # later one (`class A` then `class A < B`).
    def self.merge_class(classes, name, info)
      if (cur = classes[name])
        if cur[:super].nil? && info[:super] && cur[:kind] == info[:kind]
          classes[name] = cur.merge(info.slice(:super, :super_args))
        end
      else
        classes[name] = info
      end
    end

    def self.walk(decl, ns, methods, classes, include_private = false)
      return unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

      name = decl.name.to_s.delete_prefix("::")
      full = ns.empty? || decl.name.absolute? ? name : "#{ns}::#{name}"
      kind = decl.is_a?(RBS::AST::Declarations::Class) ? "class" : "module"
      info = { kind: kind, super: nil }
      if decl.respond_to?(:super_class) && (s = decl.super_class)
        info[:super] = s.name.to_s.delete_prefix("::")
        info[:super_args] = s.args.map(&:to_s) unless s.args.empty?
      end
      merge_class(classes, full, info)
      section = :public
      add = lambda do |key, sigs, visibility|
        return if !include_private && visibility == :private && !key.end_with?("#initialize")

        methods[key] = dots_last(methods[key] | sigs)
      end
      decl.members.each do |m|
        case m
        when RBS::AST::Members::Private then section = :private
        when RBS::AST::Members::Public then section = :public
        when RBS::AST::Members::MethodDefinition
          sigs = m.overloads.map { |o| o.method_type.to_s }
          sigs << "..." if m.overloading?
          # `private`/`public` sections apply to instance methods only;
          # `def self?.x` is a private instance method and a public
          # singleton method.
          case m.kind
          when :singleton then add.("#{full}.#{m.name}", sigs, m.visibility || :public)
          when :singleton_instance
            add.("#{full}##{m.name}", sigs, m.visibility || section)
            add.("#{full}.#{m.name}", sigs, :public)
          else add.("#{full}##{m.name}", sigs, m.visibility || section)
          end
        when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor, RBS::AST::Members::AttrWriter
          sep = m.kind == :singleton ? "." : "#"
          visibility = m.visibility || (m.kind == :singleton ? :public : section)
          unless m.is_a?(RBS::AST::Members::AttrWriter)
            add.("#{full}#{sep}#{m.name}", ["() -> #{m.type}"], visibility)
          end
          unless m.is_a?(RBS::AST::Members::AttrReader)
            add.("#{full}#{sep}#{m.name}=", ["(#{m.type}) -> #{m.type}"], visibility)
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
