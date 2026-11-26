# frozen_string_literal: true

require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "shellwords"
require "stringio"
require "set"

module GemTypes
  # Checks a signature file against the gem itself.
  module Verify
    module_function

    # Signature files that do not parse (or cannot be read). Raised before
    # any check, so broken RBS is never reported as passing.
    class SigError < StandardError; end

    # Parses every signature file strictly. Returns [[file, decls], ...].
    # Raises SigError naming each file that does not parse.
    def parse_sigs(sig)
      files = sig_files(sig)
      raise SigError, "no .rbs files in #{sig}" if files.empty?

      errors = []
      parsed = files.filter_map do |f|
        _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: f, content: File.read(f, encoding: "UTF-8")))
        [f, decls]
      rescue RBS::BaseError, SystemCallError, ArgumentError, EncodingError => e
        msg = e.message.lines.first.to_s.strip
        errors << (msg.start_with?(f) ? msg : "#{f}: #{msg}")
        nil
      end
      raise SigError, "RBS does not parse:\n  #{errors.join("\n  ")}" unless errors.empty?

      parsed
    end

    # Prints a SigError and returns exit code 2.
    def sig_error(err)
      puts "RBS ERROR: #{err.message}"
      2
    end

    # Classes and aliases as the RBS AST states them, with what name
    # resolution needs: { classes: { "A::B" => { kind:, supers: [...] } },
    # aliases: [[owner, sep, new_name, old_name]] }. Each super is
    # { name:, absolute:, context: [enclosing full names, innermost first] }.
    def sig_structure(parsed)
      classes = {}
      aliases = []
      walk = lambda do |decl, outer|
        is_class = decl.is_a?(RBS::AST::Declarations::Class)
        next unless is_class || decl.is_a?(RBS::AST::Declarations::Module)

        name = decl.name.to_s.delete_prefix("::")
        full = outer.empty? || decl.name.absolute? ? name : "#{outer.first}::#{name}"
        info = (classes[full] ||= { kind: is_class ? "class" : "module", supers: [] })
        if is_class && decl.super_class
          info[:supers] << { name: decl.super_class.name.to_s.delete_prefix("::"),
                             absolute: decl.super_class.name.absolute?, context: outer }
        end
        decl.members.each do |m|
          case m
          when RBS::AST::Members::Alias
            aliases << [full, m.kind == :singleton ? "." : "#", m.new_name.to_s, m.old_name.to_s]
          when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
            walk.(m, [full] + outer)
          end
        end
      end
      parsed.each { |_, decls| decls.each { |d| walk.(d, []) } }
      { classes: classes, aliases: aliases }
    end

    # Absolute names a superclass reference may mean, in RBS's lookup order
    # (the enclosing namespaces of the class declaration, innermost first).
    # A name the RBS itself declares wins, as it does for RBS.
    def super_candidates(sup, declared)
      return [sup[:name]] if sup[:absolute]

      all = sup[:context].map { |ns| "#{ns}::#{sup[:name]}" } + [sup[:name]]
      mine = all.find { |n| declared.include?(n) }
      mine ? [mine] : all
    end

    # Loads the gem and checks that every method, alias, class and
    # superclass the RBS declares really exists. Catches declarations of
    # methods that do not exist, which type-checking tests cannot see.
    # Returns an exit code (2: the RBS does not parse or declares nothing).
    def exists(config, sig)
      parsed = begin
        parse_sigs(sig)
      rescue SigError => e
        return sig_error(e)
      end
      st = sig_structure(parsed)
      rbs = RbsReader.read_files(parsed.map(&:first), include_private: true)
      keys = rbs.methods.keys
      if keys.empty? && st[:classes].empty?
        puts "RBS ERROR: nothing declared in #{sig}"
        return 2
      end
      classes = st[:classes].to_h do |name, info|
        sup = info[:supers].first
        # A class declared without a superclass is a subclass of Object,
        # except a reopened class from outside the gem (String, ...).
        check = sup || config.in_ns?("#{name}#x")
        [name, { "kind" => info[:kind], "check_super" => !!check,
                 "super" => sup && super_candidates(sup, st[:classes]), "super_label" => sup && sup[:name] }]
      end
      aliases = st[:aliases].map { |owner, sep, new, old| ["#{owner}#{sep}#{new}", "#{owner}#{sep}#{old}"] }
      input = { "keys" => keys, "classes" => classes, "aliases" => aliases, "requires" => config.requires }
      Dir.mktmpdir do |tmp|
        File.write(File.join(tmp, "in.json"), JSON.generate(input))
        File.write(File.join(tmp, "check.rb"), EXISTS_SCRIPT)
        out = File.join(tmp, "out.json")
        rubyopt = [config.lib_paths.map { |d| "-I#{d}" }, config.env["RUBYOPT"]].flatten.compact.join(" ")
        src = Sources::Base.new(config)
        log = File.join(config.out, "exists.log")
        ok = src.sh(config.env.merge("RUBYOPT" => rubyopt),
                    "bundle exec ruby #{File.join(tmp, 'check.rb').shellescape} " \
                    "#{File.join(tmp, 'in.json').shellescape} #{out.shellescape}",
                    chdir: config.repo, log: log)
        unless ok && File.exist?(out)
          puts "EXISTS CHECK DID NOT RUN (see #{log})"
          return 2
        end

        res = JSON.parse(File.read(out))
        problems = res["problems"]
        puts "#{res['checked']} methods (#{aliases.size} aliases) and #{classes.size} classes/modules checked against the loaded gem."
        if problems.empty?
          puts "Everything declared exists."
          return 0
        end
        # Long runs of the same problem (e.g. methods made by method_missing)
        # are shortened.
        problems.group_by { |p| p.sub(/\A\S+/, "") }.each do |reason, list|
          list.first(10).each { |p| puts "  #{p}" }
          puts "  ... and #{list.size - 10} more#{reason}" if list.size > 10
        end
        1
      end
    end

    EXISTS_SCRIPT = <<~'RUBY'
      require "json"
      input = JSON.parse(File.read(ARGV[0]))
      input["requires"].each { |r| require r }
      problems = []
      name_of = Module.instance_method(:name)
      find = ->(name) { name.split("::").inject(Object) { |m, c| m.const_get(c, false) } rescue nil }
      input["classes"].each do |name, info|
        mod = find.(name)
        if mod.nil?
          problems << "#{name}: constant not found"
        elsif !mod.is_a?(Module)
          problems << "#{name}: not a class or module (#{mod.class})"
        elsif info["kind"] == "class" && !mod.is_a?(Class)
          problems << "#{name}: declared as class but is a module"
        elsif info["kind"] == "module" && mod.is_a?(Class)
          problems << "#{name}: declared as module but is a class"
        elsif info["kind"] == "class" && info["check_super"]
          want = info["super"] ? info["super"].lazy.map { |n| find.(n) }.find { |m| m.is_a?(Class) } : Object
          label = info["super_label"] || "nothing (Object)"
          # An anonymous intermediate class (`class Foo < Struct.new(:a)`)
          # stands between the class and the declared superclass.
          actual = mod.superclass
          actual = actual.superclass while actual && name_of.bind_call(actual).nil?
          if want.nil?
            problems << "#{name}: superclass #{label} not found (tried #{info['super'].join(', ')})"
          elsif actual != want
            wn = name_of.bind_call(want)
            problems << "#{name}: superclass is #{actual.inspect}, RBS says #{label}#{wn == label || want == Object ? '' : " (#{wn})"}"
          end
        end
      end
      defined = lambda do |key|
        i = key.rindex(/[#.]/)
        owner, sep, meth = key[0...i], key[i], key[(i + 1)..]
        mod = find.(owner)
        next nil unless mod.is_a?(Module)

        if sep == "."
          mod.singleton_class.method_defined?(meth) || mod.singleton_class.private_method_defined?(meth)
        elsif meth == "initialize"
          true
        else
          mod.method_defined?(meth) || mod.private_method_defined?(meth)
        end
      end
      checked = 0
      input["keys"].each do |key|
        ok = defined.(key)
        next if ok.nil? # owner not found: reported above

        checked += 1
        next if ok

        i = key.rindex(/[#.]/)
        mod = find.(key[0...i])
        mm = key[i] == "." ? mod.singleton_class : mod
        via = (mm.instance_method(:method_missing).owner != BasicObject rescue false) ? " (method_missing defined: may be handled there)" : ""
        problems << "#{key}: no such method#{via}"
      end
      input["aliases"].each do |new, old|
        problems << "#{new}: alias of #{old}, which does not exist" if defined.(old) == false
      end
      File.write(ARGV[1], JSON.generate("checked" => checked, "problems" => problems))
    RUBY

    # Diagnostics that compare the code with the signatures (not the many
    # that only say the gem's own code is untyped).
    STEEP_RELEVANT = %w[
      MethodBodyTypeMismatch ReturnTypeMismatch MethodArityMismatch MethodParameterMismatch
      DifferentMethodParameterKind ArgumentTypeMismatch UnexpectedPositionalArgument
      InsufficientPositionalArguments UnexpectedKeywordArgument InsufficientKeywordArguments
      UnresolvedOverloading IncompatibleAssignment BlockTypeMismatch BlockBodyTypeMismatch
      RequiredBlockMissing UnexpectedBlockGiven UndeclaredMethodDefinition
      UnexpectedYield SetterBodyTypeMismatch SetterReturnTypeMismatch ClassModuleMismatch
      BreakTypeMismatch UnexpectedSuper IncompatibleArgumentForwarding
    ].freeze

    # Diagnostics at a call site that are about the callee's signature, so
    # they matter wherever the caller is (also in undeclared methods).
    STEEP_CALL_SITE = %w[
      ArgumentTypeMismatch UnexpectedPositionalArgument InsufficientPositionalArguments
      UnexpectedKeywordArgument InsufficientKeywordArguments UnresolvedOverloading
      BlockTypeMismatch RequiredBlockMissing UnexpectedBlockGiven
    ].freeze

    # Ruby diagnostics that mean Steep could not check (part of) the code.
    STEEP_BROKEN = %w[UnexpectedError SyntaxError RBSError LibraryRBSError].freeze

    # Type-checks the gem's library code against the signatures with Steep
    # and lists the diagnostics that involve a signature, per method.
    # Returns 0 (clean), 1 (mismatches or signature errors) or 2 (the RBS
    # does not parse, or Steep did not finish).
    def steep(config, sig, libraries)
      files = begin
        parse_sigs(sig).map(&:first)
      rescue SigError => e
        return sig_error(e)
      end
      dir = File.join(config.out, "steep")
      FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
      config.lib_paths.each_with_index { |d, i| File.symlink(d, File.join(dir, "lib#{i}")) }
      FileUtils.mkdir_p(File.join(dir, "sig"))
      copies = {}
      files.each_with_index do |f, i|
        copy = File.join("sig", "#{i}_#{File.basename(f)}")
        FileUtils.cp(f, File.join(dir, copy))
        copies[copy] = f
      end
      # The dependencies' signatures too (their manifest libraries included).
      deps = dep_sigs(config, sig)
      dep_dirs = deps.filter_map { |k, v| v if k == :s }
      libraries = (libraries + deps.filter_map { |k, v| v if k == :l } + dep_dirs.flat_map { |d| manifest_libraries(d) }).uniq
      dep_dirs.each_with_index { |d, i| File.symlink(d, File.join(dir, "dep#{i}")) }
      File.write(File.join(dir, "Steepfile"), <<~RUBY)
        D = Steep::Diagnostic
        target :lib do
          #{config.lib_paths.each_index.map { |i| "check \"lib#{i}\"" }.join("\n  ")}
          signature "sig"#{dep_dirs.each_index.map { |i| ", \"dep#{i}\"" }.join}
          #{libraries.map { |l| "library #{l.dump}" }.join("\n  ")}
          configure_code_diagnostics(D::Ruby.all_error)
        end
      RUBY
      log = File.join(config.out, "steep.log")
      src = Sources::Base.new(config)
      # steep exits 1 when it finds errors, which is the normal case here.
      src.sh({}, "#{src.tool_bin('steep')} check --format=github --severity-level=error > steep.out 2>&1; true",
             chdir: dir, log: log, tool: true)
      out_file = File.join(dir, "steep.out")
      text = File.exist?(out_file) ? File.read(out_file, encoding: "UTF-8").scrub : ""
      # Without its summary line Steep crashed or never ran: not "clean".
      unless text.match?(/^(No type error detected|Detected \d+ problems?)/)
        puts "STEEP DID NOT FINISH: no summary line in its output; the code was not checked."
        text.lines.last(15).each { |l| puts "  #{l.chomp[0, 220]}" }
        puts "(full output: #{out_file}; log: #{log})"
        return 2
      end
      lines = text.lines(chomp: true).grep(/\A::error /)
      parsed = lines.filter_map do |l|
        m = l.match(/file=([^,]+),line=(\d+)(?:.*?,col=(\d+))?.*?::\[(Ruby|RBS)::(\w+)\] (.*)/) or next
        { file: m[1], line: m[2].to_i, col: m[3]&.to_i, group: m[4], kind: m[5], msg: m[6] }
      end
      # Errors in the signatures themselves (unknown type names, duplicate
      # declarations, ...) and Steep's own failures: always fatal.
      sig_errs = parsed.select { |d| d[:group] == "RBS" }
      broken = parsed.select { |d| d[:group] == "Ruby" && STEEP_BROKEN.include?(d[:kind]) }
      defs = DefIndex.new(config.lib_paths).to_a
      rbs = RbsReader.read_files(files, include_private: true)
      declared = rbs.classes.keys
      declared_names = rbs.methods.keys.to_set { |k| GemTypes.split_key(k).last }
      declared_names << "new" if declared_names.include?("initialize")
      source_lines = Hash.new { |h, f| h[f] = (File.readlines(f, chomp: true, encoding: "UTF-8").map(&:scrub) rescue []) }
      hits = parsed.filter_map do |d|
        next unless d[:group] == "Ruby" && STEEP_RELEVANT.include?(d[:kind])

        file = File.expand_path(d[:file].sub(/\Alib(\d+)/) { config.lib_paths[$1.to_i] }, dir)
        line = d[:line]
        owner = defs.select { |x| x[:file] == file && x[:line] <= line && line <= x[:end_line] }.max_by { |x| x[:line] }
        key = owner ? owner[:key] : "#{file.delete_prefix("#{config.repo}/")}:#{line}"
        [key, d[:kind], d[:msg], source_lines[file][line - 1].to_s]
      end
      hits.select! do |key, kind, msg, code|
        next true if kind == "UndeclaredMethodDefinition"

        method_key = key.match?(/\A[\w:]+[#.][^\s:]+\z/)
        next true unless method_key # outside any def: keep

        owner = GemTypes.split_key(key).first
        # Methods the RBS declares: an undeclared method checked against an
        # inherited signature (method_missing, ==, ...) is not ours.
        next true if declared.include?(owner) && rbs.methods.key?(key)
        # A call-site mismatch is about the callee's signature, wherever
        # the caller is; keep it when it involves the RBS under test (a
        # type it declares, or a call to a method name it declares), not
        # calls to untyped or library methods.
        next false unless STEEP_CALL_SITE.include?(kind)

        types = msg.scan(/(?<![\w:])(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)/).flatten
        types.any? { |t| declared.include?(t) } ||
          code.scan(/(?<![\w@$:])[a-z_]\w*[?!]?/).any? { |n| declared_names.include?(n) }
      end
      hits.map! { |h| h.first(3) }
      undeclared, mismatches = hits.partition { |_, kind, _| kind == "UndeclaredMethodDefinition" }
      puts "Steep: #{lines.size} errors in the gem's code; #{mismatches.size} where code and signatures disagree."
      unless sig_errs.empty?
        puts "ERRORS IN THE SIGNATURES (#{sig_errs.size}):"
        sig_errs.uniq.each do |d|
          f = copies[d[:file]] || d[:file]
          puts "  #{f}:#{d[:line]}: RBS::#{d[:kind]}: #{d[:msg][0, 200]}"
        end
      end
      unless broken.empty?
        puts "STEEP COULD NOT CHECK PART OF THE CODE (#{broken.size}):"
        broken.uniq.each do |d|
          f = File.expand_path(d[:file].sub(/\Alib(\d+)/) { config.lib_paths[$1.to_i] }, dir).delete_prefix("#{config.repo}/")
          puts "  #{f}:#{d[:line]}: Ruby::#{d[:kind]}: #{d[:msg][0, 200]}"
        end
      end
      mismatches.group_by(&:first).sort.each do |key, list|
        puts "  #{key}"
        list.uniq.each { |_, kind, msg| puts "    #{kind}: #{msg[0, 200]}" }
      end
      unless undeclared.empty?
        names = undeclared.map(&:first).uniq.sort
        puts "Defined in the code but not declared (#{names.size}; fine if internal on purpose):"
        puts "  #{names.join(', ')}"
      end
      puts "(full output: #{out_file})"
      mismatches.empty? && sig_errs.empty? && broken.empty? ? 0 : 1
    end

    # Runs the gem's own test suite twice, without and with RBS runtime type
    # checking (log mode), and summarizes: examples, failures in each run,
    # number of type checks, distinct type errors. Returns the summary hash;
    # :incomplete lists why the checked run cannot be trusted (it crashed,
    # ran fewer tests than the plain run, recorded no type checks, ...),
    # nil when it is complete.
    def suite(config, sig)
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      raise "no test command (pass --test-cmd)" unless config.test_cmd

      targets = config.ns.flat_map { |n| [n, "#{n}::*"] }.join(",")
      double = config.test_cmd.include?("rspec") ? "rspec" : "minitest"
      prefix = File.join(config.out, "suite")
      FileUtils.mkdir_p(config.out)
      src = Sources::Base.new(config)
      plain_log = File.join(config.out, "suite-plain.log")
      plain_ok = src.sh(config.env, GemTypes.timed(config.test_cmd), chdir: config.repo, log: plain_log)
      check = File.join(LIBEXEC, "rbs_check.sh")
      checked_log = File.join(config.out, "suite-checked.log")
      calls = "#{prefix}.calls"
      FileUtils.rm_f(calls)
      # rbs_check.sh -o clears these too; a run that never gets that far
      # must not pick up an earlier run's numbers.
      FileUtils.rm_f(["#{prefix}.checked.tsv", "#{prefix}.errors.tsv"])
      deps = dep_sig_args(config, sig)
      checked_ok = src.sh(config.env, "#{check.shellescape} -s #{sigdir.shellescape}#{deps} -t #{targets.shellescape} -d #{double} " \
                                      "-o #{prefix.shellescape} -c #{calls.shellescape} -- #{GemTypes.timed(config.test_cmd)}",
                          chdir: config.repo, log: checked_log)
      plain = test_counts(File.read(plain_log, encoding: "UTF-8"))
      checked = test_counts(File.read(checked_log, encoding: "UTF-8"))
      checks = File.exist?("#{prefix}.checked.tsv") ? File.readlines("#{prefix}.checked.tsv").sum { _1.to_i } : 0
      # One line per process and error: merge by message.
      errors = if File.exist?("#{prefix}.errors.tsv")
                 File.readlines("#{prefix}.errors.tsv", chomp: true, encoding: "UTF-8").reject(&:empty?)
                     .group_by { |l| l.split("\t")[1] }
                     .map { |msg, ls| "#{ls.sum(&:to_i)}x\t#{msg}\t#{ls.first.split("\t")[2]}" }
                     .sort_by { |l| -l.to_i }
               else
                 []
               end
      incomplete = incomplete_reasons(plain, checked, checks, plain_ok: plain_ok, checked_ok: checked_ok)
      unc = File.exist?(calls) ? uncalled(sig, calls, private: true) : nil
      { plain: plain, checked: checked, checks: checks, errors: errors,
        uncalled: unc&.reject { |k| k.end_with?(" (private)") },
        uncalled_private: unc&.select { |k| k.end_with?(" (private)") }&.map { |k| k.delete_suffix(" (private)") },
        plain_ok: plain_ok, checked_ok: checked_ok, incomplete: incomplete,
        errors_file: "#{prefix}.errors.tsv", logs: [plain_log, checked_log] }
    end

    # Why a checked test run cannot be compared with the plain one (empty
    # when it can): only a complete run backs "no type errors".
    def incomplete_reasons(plain, checked, checks, plain_ok: true, checked_ok: true)
      r = []
      r << "the checked run counted no tests" unless checked[:total].positive?
      if checked[:total] < plain[:total]
        r << "the checked run ran fewer #{plain[:unit]} (#{checked[:total]}) than the plain run (#{plain[:total]})"
      end
      r << "no type checks were recorded" unless checks.positive?
      if checked[:failed] > plain[:failed]
        r << "more failures with checking (#{checked[:failed]}) than without (#{plain[:failed]})"
      end
      r << "the checked run exited non-zero but the plain run did not" if plain_ok && !checked_ok
      r
    end

    # Declared methods the run never called (coverage_report.rb per file).
    # Private ones end in " (private)" when private: true, else are left out.
    def uncalled(sig, calls, private: false)
      script = File.join(LIBEXEC, "coverage_report.rb")
      sig_files(sig).flat_map do |f|
        out = IO.popen([RbConfig.ruby, script, f, calls], err: File::NULL, &:read)
        out.lines(chomp: true).reject { |l| !private && l.end_with?("(private)") }
      end.uniq
    end

    # Proves the runtime checks really cover each declaration: runs `cmd`
    # under rbs/test with a copy of the signatures where every return type
    # (and attr type) is `bot`, so every checked call must fail. Declared
    # methods that never fail were not checked by this run: never called,
    # inherited rather than defined by the class (rbs/test only hooks a
    # class's own methods), or hidden from the hook. Private declarations
    # are included. Returns { checked: [...], unchecked: [...], skipped:
    # [...] (initialize), aliases: [...] (alias declarations that did not
    # fail: not mutated themselves) }. Raises SigError when the RBS does not
    # parse.
    def live(config, sig, cmd)
      parsed = parse_sigs(sig)
      files = parsed.map(&:first)
      dir = File.join(config.out, "live")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      manifest = File.join(sigdir, "manifest.yaml")
      FileUtils.cp(manifest, File.join(dir, "sig")) if File.exist?(manifest)
      files.each_with_index do |f, i|
        _, dirs, decls = RBS::Parser.parse_signature(File.read(f, encoding: "UTF-8"))
        io = StringIO.new
        w = RBS::Writer.new(out: io)
        w.write(dirs + decls.map { |d| bottomize(d) })
        File.write(File.join(dir, "sig", "#{i}_#{File.basename(f)}"), io.string)
      end
      # Classes outside the gem's namespace that the RBS reopens (String,
      # Kernel, ...) are targets too, so the methods the gem adds to them
      # are checked; only the methods the RBS declares for them are hooked
      # (RBS_TEST_ONLY_METHODS, see libexec/rbs_hook_fix.rb).
      rbs = RbsReader.read_files(files, include_private: true)
      reopened = rbs.classes.keys.reject { |c| config.in_ns?("#{c}#x") }
      targets = (config.ns.flat_map { |n| [n, "#{n}::*"] } + reopened).join(",")
      prefix = File.join(dir, "run")
      src = Sources::Base.new(config)
      check = File.join(LIBEXEC, "rbs_check.sh")
      double = cmd.include?("rspec") ? "rspec" : "minitest"
      only = rbs.methods.keys.select { |k| reopened.include?(GemTypes.split_key(k).first) }
      env = only.empty? ? config.env : config.env.merge("RBS_TEST_ONLY_METHODS" => only.join(","))
      ok = src.sh(env, "#{check.shellescape} -s #{File.join(dir, 'sig').shellescape}#{dep_sig_args(config, sig)} -t #{targets.shellescape} " \
                       "-d #{double} -o #{prefix.shellescape} -- #{GemTypes.timed(cmd)}",
                  chdir: config.repo, log: File.join(dir, "run.log"))
      failed = File.exist?("#{prefix}.errors.tsv") ? File.readlines("#{prefix}.errors.tsv", encoding: "UTF-8").filter_map { |l| l[/\t\[(.+?)\] \w+Error/, 1] }.uniq : []
      alias_keys, keys = rbs.methods.keys.partition { |k| rbs.methods[k].all? { |x| x.start_with?("(alias of") } }
      skipped, keys = keys.partition { |k| k.end_with?("#initialize") }
      # `def self?.m` (module_function): the instance copy is private and
      # normally not called; the singleton one stands for both.
      keys.reject! do |k|
        owner, sep, name = GemTypes.split_key(k)
        sep == "#" && keys.include?("#{owner}.#{name}") && !failed.include?(k)
      end
      checked, unchecked = keys.partition { |k| failed.include?(k) }
      alias_checked, aliases = alias_keys.partition { |k| failed.include?(k) }
      { checked: (checked + alias_checked).sort, unchecked: unchecked.sort, skipped: skipped.sort,
        aliases: aliases.sort, private: rbs_private_keys(parsed), ok: ok, log: File.join(dir, "run.log") }
    end

    # Keys of the private declarations (def, attr_*, alias) in parsed RBS.
    def rbs_private_keys(parsed)
      pub = RbsReader.read_files(parsed.map(&:first)).methods.keys
      RbsReader.read_files(parsed.map(&:first), include_private: true).methods.keys - pub
    end

    def bottomize(decl)
      bot = RBS::Types::Bases::Bottom.new(location: nil)
      case decl
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        decl.update(members: decl.members.map { |m| bottomize(m) })
      when RBS::AST::Members::MethodDefinition
        return decl if decl.name == :initialize

        decl.update(overloads: decl.overloads.map do |o|
          o.update(method_type: o.method_type.update(type: o.method_type.type.with_return_type(bot)))
        end)
      when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrWriter, RBS::AST::Members::AttrAccessor
        decl.update(type: bot)
      else
        decl
      end
    end

    # Mistakes found in reviews that the source shows directly. Returns
    # [[key, message], ...]:
    # - the method takes an options Hash positionally (`opts = {}`) but the
    #   RBS only accepts keywords: `new(hash_variable)` is rejected;
    # - the method refers to Fixnum/Bignum, so it raises NameError on Ruby
    #   3.2 and later: declare it only if some path avoids the reference.
    def lint(config, sig)
      rbs = RbsReader.read_files(parse_sigs(sig).map(&:first), include_private: true)
      out = []
      DefIndex.new(config.lib_paths).each do |d|
        sigs = rbs.methods[d[:key]] || (d[:key].end_with?("#initialize") ? rbs.methods[d[:key].sub("#initialize", ".new")] : nil)
        next unless sigs

        if (msg = options_hash_lint(d[:params], sigs))
          out << [d[:key], msg]
        end
        unless d[:legacy_consts].empty?
          out << [d[:key], "refers to #{d[:legacy_consts].join(', ')} (removed in Ruby 3.2): check whether every call raises NameError"]
        end
      end
      out.uniq
    end

    # `def m(name, opts = {})` with an RBS that only takes keywords where
    # the Hash goes: `m(x, hash_variable)` is rejected. The Hash must be the
    # last positional parameter and the method must take no keywords; some
    # overload has to accept a positional argument at its index.
    def options_hash_lint(params, sigs)
      idx = params.index { |p| p[:kind] == "opt" && p[:hash_default] } or return nil
      hash_param = params[idx]
      return nil if params.any? { |p| %w[rest keyreq key keyrest].include?(p[:kind]) }
      return nil if params[(idx + 1)..].any? { |p| %w[req opt].include?(p[:kind]) }

      pos = params[0...idx].count { |p| %w[req opt].include?(p[:kind]) }
      types = sigs.reject { |x| x.start_with?("(alias of") }.filter_map { |x| RBS::Parser.parse_method_type(x).type rescue nil }
                  .select { |f| f.is_a?(RBS::Types::Function) }
      return nil if types.empty?

      accepts = types.any? do |f|
        f.rest_positionals || (f.required_positionals.size + f.optional_positionals.size + f.trailing_positionals.size) > pos
      end
      keywords = types.any? { |f| f.optional_keywords.any? || f.required_keywords.any? || f.rest_keywords }
      return nil if accepts || !keywords

      lead = params[0...idx].select { |p| %w[req opt].include?(p[:kind]) }.map { |p| "#{p[:kind] == 'opt' ? '?' : ''}untyped #{p[:name]}" }
      args = (lead + ["?Hash[Symbol, untyped] #{hash_param[:name]}"]).join(", ")
      "takes `#{hash_param[:name]} = {}` positionally but the RBS only accepts keywords; add `| (#{args}) -> ...`"
    end

    # Declared types wider than anything the test suite passed or got back:
    # union members and `untyped` never matched by an observed value, per
    # parameter and return type. Uses tracepoint evidence (W/evidence).
    # Returns [[key, slot, message], ...]. Informational: tests rarely cover
    # every accepted type, but each line is worth a look.
    def too_wide(config, sig)
      tp = Sources.for("tracepoint", config)
      observed = tp.read
      return nil if observed.empty?

      anc = tp.ancestors
      rbs = RbsReader.read_files(sig_files(sig))
      out = []
      rbs.methods.each do |key, sigs|
        e = observed[key] or next
        next if e.calls.to_i.zero? || e.returns.empty? || sigs.any? { |x| x.start_with?("(alias of") }

        owner = GemTypes.split_key(key).first
        slots = Hash.new { |h, k| h[k] = [] }
        sigs.each do |str|
          mt = RBS::Parser.parse_method_type(str) rescue next
          f = mt.type
          next unless f.is_a?(RBS::Types::Function)

          pos = f.required_positionals + f.optional_positionals
          pos.each_with_index { |p, i| slots[[:pos, i]] << p.type }
          slots[[:rest]] << f.rest_positionals.type if f.rest_positionals
          (f.required_keywords.to_a + f.optional_keywords.to_a).each { |k, p| slots[[:key, k.to_s]] << p.type }
          slots[[:ret]] << f.return_type unless mt.type_params.any? { |tp_| f.return_type.to_s == tp_.name.to_s }
        end
        seen = observed_slots(e)
        slots.each do |slot, types|
          obs = seen[slot] or next
          next if obs.empty? || obs.any? { |t| t.include?("(anon)") || t == "?" }

          members = types.flat_map { |t| members(t) }.uniq
          label = slot_label(slot, e)
          if members.include?(:untyped)
            out << [key, label, "untyped, but only #{obs.sort.join(' | ')} seen"]
            next
          end
          members.each do |m|
            next if m.is_a?(Symbol)
            next if obs.any? { |o| satisfies?(o, m, owner, anc) }

            out << [key, label, "#{m} never seen (seen: #{obs.sort.join(' | ')})"]
          end
        end
      end
      out
    end

    # Parameters declared as Hash[K, V] / Array[T] with concrete type
    # arguments that the test suite passed a subclass of Hash/Array to
    # (faraday_middleware's Chunked#chunked_encoding? gets a
    # Faraday::Utils::Headers < Hash[Symbol | String, untyped]). The
    # subclass itself is not the problem: type arguments are invariant, so
    # the arguments it inherits must match the declared ones exactly. Use
    # untyped arguments or an interface when the method only reads.
    # Returns [[key, slot, message], ...].
    def invariant_params(config, sig)
      tp = Sources.for("tracepoint", config)
      observed = tp.read
      return [] if observed.empty?

      anc = tp.ancestors
      rbs = RbsReader.read_files(sig_files(sig))
      out = []
      rbs.methods.each do |key, sigs|
        e = observed[key] or next
        owner = GemTypes.split_key(key).first
        seen = observed_slots(e)
        sigs.each do |str|
          mt = RBS::Parser.parse_method_type(str) rescue next
          f = mt.type
          next unless f.is_a?(RBS::Types::Function)

          slots = {}
          (f.required_positionals + f.optional_positionals).each_with_index { |p, i| slots[[:pos, i]] = p.type }
          slots[[:rest]] = f.rest_positionals.type if f.rest_positionals
          (f.required_keywords.to_a + f.optional_keywords.to_a).each { |k, p| slots[[:key, k.to_s]] = p.type }
          slots.each do |slot, type|
            generic = flat_class_instances(type).select do |t|
              %w[Hash Array].include?(t.name.to_s.delete_prefix("::")) && t.args.any? && !t.args.all? { |a| a.is_a?(RBS::Types::Bases::Any) }
            end
            next if generic.empty?

            (seen[slot] || []).each do |o|
              head = o[/\A[\w:]+/] or next
              generic.each do |g|
                base = g.name.to_s.delete_prefix("::")
                next if head == base || !(anc[head] || core_ancestors(head) || []).include?(base)

                out << [key, slot_label(slot, e), "the tests passed a #{head} (a #{base} subclass); its #{base} type arguments must match #{g} exactly (invariant)"]
              end
            end
          end
        end
      end
      out.uniq
    end

    def flat_class_instances(type)
      case type
      when RBS::Types::Union then type.types.flat_map { |t| flat_class_instances(t) }
      when RBS::Types::Optional then flat_class_instances(type.type)
      when RBS::Types::ClassInstance then [type]
      else []
      end
    end

    def observed_slots(e)
      h = {}
      i = 0
      (e.params || []).each do |p|
        case p[:kind]
        when "req", "opt" then h[[:pos, i]] = p[:types]; i += 1
        when "rest" then h[[:rest]] = p[:types]
        when "key", "keyreq" then h[[:key, p[:name]]] = p[:types]
        end
      end
      h[[:ret]] = e.always?(e.self_returns) ? [] : e.returns
      h.transform_values { |ts| ts - ["(none)"] }
    end

    def slot_label(slot, e)
      case slot[0]
      when :ret then "return"
      when :rest then "*rest"
      when :key then "#{slot[1]}:"
      else
        pos = (e.params || []).select { |p| %w[req opt].include?(p[:kind]) }
        pos[slot[1]] ? pos[slot[1]][:name] : "arg #{slot[1] + 1}"
      end
    end

    # Class names a type accepts; :untyped, or :skip for what we cannot check.
    def members(type)
      case type
      when RBS::Types::Union then type.types.flat_map { |t| members(t) }
      when RBS::Types::Optional then members(type.type) + ["nil"]
      when RBS::Types::Bases::Any then [:untyped]
      when RBS::Types::Bases::Nil then ["nil"]
      when RBS::Types::Bases::Bool then ["bool"]
      when RBS::Types::Literal
        case type.literal
        when true, false then ["bool"]
        else [type.literal.class.name]
        end
      when RBS::Types::ClassInstance then [type.name.to_s.delete_prefix("::")]
      when RBS::Types::ClassSingleton then ["singleton(#{type.name.to_s.delete_prefix('::')})"]
      when RBS::Types::Tuple then ["Array"]
      when RBS::Types::Record then ["Hash"]
      else [:skip] # interfaces, aliases, self, type variables, procs, void
      end
    end

    # Does an observed type string (from the TracePoint hook) satisfy a
    # declared class name? Relative names in the RBS are tried against the
    # owner's namespaces.
    def satisfies?(obs, member, owner, anc)
      return obs == "bool" if member == "bool"
      return obs == "nil" if member == "nil"
      return %w[Object BasicObject Kernel].include?(member) || obs == member if obs == "nil" || obs == "bool"

      if member.start_with?("singleton(")
        return false unless obs.start_with?("singleton(")

        # singleton(Foo) accepts Foo and its subclasses.
        inner = obs[10..-2]
        chain = anc[inner] || core_ancestors(inner) || [inner]
        return names(member[10..-2], owner).any? { |n| chain.include?(n) }
      end
      if obs.start_with?("singleton(")
        # A class or module object: an instance of Class (or Module).
        inner = obs[10..-2]
        chain = anc[inner] || core_ancestors(inner)
        is_module = chain && !chain.include?("BasicObject") && !chain.include?("Object")
        return %w[Module Object BasicObject Kernel].include?(member) || (member == "Class" && !is_module)
      end
      head = obs[/\A[\w:]+/] or return true
      chain = anc[head] || core_ancestors(head) || [head]
      names(member, owner).any? { |n| chain.include?(n) }
    end

    def names(member, owner)
      parts = owner.split("::")
      (0..parts.size).map { |i| (parts.first(parts.size - i) + [member]).join("::") }
    end

    def core_ancestors(name)
      c = Object.const_get(name) rescue nil
      c.is_a?(Module) ? c.ancestors.map(&:name).compact : nil
    end

    # Sums "N examples, M failures" (RSpec) and "N runs, A assertions,
    # M failures, E errors" (Minitest / test-unit) lines in a log. RSpec's
    # errors outside of examples count as failures.
    def test_counts(log)
      total = 0
      failed = 0
      unit = nil
      log.scan(/(\d+) examples?, (\d+) failures?/) { total += $1.to_i; failed += $2.to_i; unit = "examples" }
      log.scan(/(\d+) (?:runs|tests), \d+ assertions, (\d+) failures, (\d+) errors/) do
        total += $1.to_i; failed += $2.to_i + $3.to_i; unit ||= "runs"
      end
      # RSpec: "0 examples, 0 failures, 1 error occurred outside of examples"
      # (a spec file that does not load): failures, though no example failed.
      outside = 0
      log.scan(/(\d+) errors? occurred outside of examples/) { outside += $1.to_i }
      { total: total, failed: failed + outside, unit: unit || "tests", outside: outside }
    end

    # " -s <dir>" for the RBS of the gem's runtime dependencies that the
    # collection has (gems/<dep>/<version>, the newest version allowed by
    # the dependency, else the newest), so signatures can refer to them
    # (faraday_middleware's classes inherit from Faraday::Middleware).
    # The signatures of the gem's dependencies, as `rbs collection` would
    # load them: [:s, dir] for a gem in the collection, [:l, name] for a
    # library in rbs's stdlib.
    def dep_sigs(config, sig)
      gems_dir = File.expand_path(sig).split(File::SEPARATOR).then do |parts|
        i = parts.rindex("gems") or return []
        parts[0..i].join(File::SEPARATOR)
      end
      pkg = Dir[File.join(File.dirname(config.out), "*.gem")].first or return []
      require "rubygems/package"
      spec = Gem::Package.new(pkg).spec
      own = File.expand_path(File.directory?(sig) ? sig : File.dirname(sig))
      # Plus the gems _test/metadata.yaml adds for bin/test (a plugin whose
      # host library depends on it, like faraday-net_http and faraday).
      meta = File.join(own, "_test", "metadata.yaml")
      extra = File.exist?(meta) ? Array((YAML.safe_load_file(meta) || {})["additional_gems"]) : []
      deps = spec.runtime_dependencies + (extra.map(&:to_s) - spec.runtime_dependencies.map(&:name)).map { |n| Gem::Dependency.new(n) }
      deps.filter_map do |dep|
        versions = Dir[File.join(gems_dir, dep.name, "*")].select { |d| File.directory?(d) && File.basename(d).match?(/\A\d/) }
        # A default gem typed in rbs's stdlib (net-http, uri, ...), as
        # `rbs collection` resolves it.
        next(stdlib?(dep.name) ? [:l, dep.name] : nil) if versions.empty?

        sorted = versions.sort_by { |d| Gem::Version.new(File.basename(d)) }
        best = sorted.reverse.find { |d| dep.requirement.satisfied_by?(Gem::Version.new("#{File.basename(d)}.0")) } || sorted.last
        next if File.expand_path(best) == own

        [:s, best]
      end
    rescue StandardError
      []
    end

    def dep_sig_args(config, sig)
      dep_sigs(config, sig).map { |k, v| " -#{k} #{v.shellescape}" }.join
    end

    def manifest_libraries(dir)
      m = File.join(dir, "manifest.yaml")
      File.exist?(m) ? Array((YAML.safe_load_file(m) || {})["dependencies"]).map { _1["name"] } : []
    end

    def stdlib?(name)
      require "rbs"
      File.directory?(File.join(RBS::Repository::DEFAULT_STDLIB_ROOT, name))
    rescue LoadError
      false
    end

    # The .rbs files of a signature dir (or the file itself). Like `rbs
    # collection`, skips directories starting with "_" (_test/ and the like).
    def sig_files(sig)
      return [sig] unless File.directory?(sig)

      Dir[File.join(sig, "**", "*.rbs")].sort.reject do |f|
        File.dirname(f).delete_prefix(sig).split(File::SEPARATOR).any? { |part| part.start_with?("_") }
      end
    end
  end
end
