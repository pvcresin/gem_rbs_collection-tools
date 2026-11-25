# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "shellwords"
require "stringio"

module GemTypes
  # Checks a signature file against the gem itself.
  module Verify
    module_function

    # Loads the gem and checks that every method, class and superclass the
    # RBS declares really exists. Catches declarations of methods that do
    # not exist, which type-checking tests cannot see. Returns an exit code.
    def exists(config, sig)
      rbs = RbsReader.read_files(sig_files(sig), include_private: true)
      keys = rbs.methods.reject { |_, sigs| sigs.all? { |s| s.start_with?("(alias of") } }.keys
      input = { "keys" => keys, "classes" => rbs.classes, "requires" => config.requires }
      Dir.mktmpdir do |tmp|
        File.write(File.join(tmp, "in.json"), JSON.generate(input))
        File.write(File.join(tmp, "check.rb"), EXISTS_SCRIPT)
        out = File.join(tmp, "out.json")
        rubyopt = [config.lib_paths.map { |d| "-I#{d}" }, config.env["RUBYOPT"]].flatten.compact.join(" ")
        src = Sources::Base.new(config)
        ok = src.sh(config.env.merge("RUBYOPT" => rubyopt),
                    "bundle exec ruby #{File.join(tmp, 'check.rb').shellescape} " \
                    "#{File.join(tmp, 'in.json').shellescape} #{out.shellescape}",
                    chdir: config.repo, log: File.join(config.out, "exists.log"))
        return 2 unless ok && File.exist?(out)

        res = JSON.parse(File.read(out))
        problems = res["problems"]
        puts "#{res['checked']} methods and #{rbs.classes.size} classes/modules checked against the loaded gem."
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
      find = ->(name) { name.split("::").inject(Object) { |m, c| m.const_get(c, false) } rescue nil }
      input["classes"].each do |name, info|
        mod = find.(name)
        if mod.nil?
          problems << "#{name}: constant not found"
        elsif info["kind"] == "class" && !mod.is_a?(Class)
          problems << "#{name}: declared as class but is a module"
        elsif info["kind"] == "module" && mod.is_a?(Class)
          problems << "#{name}: declared as module but is a class"
        elsif info["super"] && mod.is_a?(Class)
          sup = find.(info["super"])
          problems << "#{name}: superclass is #{mod.superclass}, RBS says #{info['super']}" if sup && !(mod <= sup)
        end
      end
      checked = 0
      input["keys"].each do |key|
        i = key.rindex(/[#.]/)
        owner, sep, meth = key[0...i], key[i], key[(i + 1)..]
        mod = find.(owner) or next
        checked += 1
        ok = if sep == "."
               mod.singleton_class.method_defined?(meth) || mod.singleton_class.private_method_defined?(meth)
             elsif meth == "initialize"
               true
             else
               mod.method_defined?(meth) || mod.private_method_defined?(meth)
             end
        next if ok

        mm = sep == "." ? mod.singleton_class : mod
        via = (mm.instance_method(:method_missing).owner != BasicObject rescue false) ? " (method_missing defined: may be handled there)" : ""
        problems << "#{key}: no such method#{via}"
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
    ].freeze

    # Type-checks the gem's library code against the signatures with Steep
    # and lists the diagnostics that involve a signature, per method.
    def steep(config, sig, libraries)
      dir = File.join(config.out, "steep")
      FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
      config.lib_paths.each_with_index { |d, i| File.symlink(d, File.join(dir, "lib#{i}")) }
      FileUtils.mkdir_p(File.join(dir, "sig"))
      sig_files(sig).each_with_index { |f, i| FileUtils.cp(f, File.join(dir, "sig", "#{i}_#{File.basename(f)}")) }
      File.write(File.join(dir, "Steepfile"), <<~RUBY)
        D = Steep::Diagnostic
        target :lib do
          #{config.lib_paths.each_index.map { |i| "check \"lib#{i}\"" }.join("\n  ")}
          signature "sig"
          #{libraries.map { |l| "library #{l.dump}" }.join("\n  ")}
          configure_code_diagnostics(D::Ruby.all_error)
        end
      RUBY
      log = File.join(config.out, "steep.log")
      src = Sources::Base.new(config)
      # steep exits 1 when it finds errors, which is the normal case here.
      src.sh({}, "#{src.tool_bin('steep')} check --format=github --severity-level=error > steep.out 2>&1; true",
             chdir: dir, log: log, tool: true)
      lines = File.readlines(File.join(dir, "steep.out"), chomp: true).grep(/\A::error /)
      defs = DefIndex.new(config.lib_paths).to_a
      hits = lines.filter_map do |l|
        m = l.match(/file=([^,]+),line=(\d+).*?::\[Ruby::(\w+)\] (.*)/) or next
        next unless STEEP_RELEVANT.include?(m[3])

        file = File.expand_path(m[1].sub(/\Alib(\d+)/) { config.lib_paths[$1.to_i] }, dir)
        line = m[2].to_i
        owner = defs.select { |d| d[:file] == file && d[:line] <= line && line <= d[:end_line] }.max_by { |d| d[:line] }
        [owner ? owner[:key] : "#{file.delete_prefix("#{config.repo}/")}:#{line}", m[3], m[4]]
      end
      # Diagnostics inside classes the RBS does not declare at all are about
      # code we did not type; drop them.
      rbs = RbsReader.read_files(sig_files(sig), include_private: true)
      declared = rbs.classes.keys
      hits.select! do |key, kind, _|
        next true if kind == "UndeclaredMethodDefinition"

        method_key = key.match?(/\A[\w:]+[#.][^\s:]+\z/)
        next true unless method_key # outside any def: keep

        owner = GemTypes.split_key(key).first
        # Only methods the RBS declares: an undeclared method checked against
        # an inherited signature (method_missing, ==, ...) is not ours.
        declared.include?(owner) && rbs.methods.key?(key)
      end
      undeclared, mismatches = hits.partition { |_, kind, _| kind == "UndeclaredMethodDefinition" }
      puts "Steep: #{lines.size} errors in the gem's code; #{mismatches.size} where code and signatures disagree."
      mismatches.group_by(&:first).sort.each do |key, list|
        puts "  #{key}"
        list.uniq.each { |_, kind, msg| puts "    #{kind}: #{msg[0, 200]}" }
      end
      unless undeclared.empty?
        names = undeclared.map(&:first).uniq.sort
        puts "Defined in the code but not declared (#{names.size}; fine if internal on purpose):"
        puts "  #{names.join(', ')}"
      end
      hits = mismatches
      puts "(full output: #{File.join(dir, 'steep.out')})"
      hits.empty? ? 0 : 1
    end

    # Runs the gem's own test suite twice, without and with RBS runtime type
    # checking (log mode), and summarizes: examples, failures in each run,
    # number of type checks, distinct type errors. Returns the summary hash.
    def suite(config, sig)
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      raise "no test command (pass --test-cmd)" unless config.test_cmd

      targets = config.ns.flat_map { |n| [n, "#{n}::*"] }.join(",")
      double = config.test_cmd.include?("rspec") ? "rspec" : "minitest"
      prefix = File.join(config.out, "suite")
      FileUtils.mkdir_p(config.out)
      src = Sources::Base.new(config)
      plain_log = File.join(config.out, "suite-plain.log")
      src.sh(config.env, config.test_cmd, chdir: config.repo, log: plain_log)
      check = File.join(LIBEXEC, "rbs_check.sh")
      checked_log = File.join(config.out, "suite-checked.log")
      calls = "#{prefix}.calls"
      FileUtils.rm_f(calls)
      deps = dep_sig_args(config, sig)
      src.sh(config.env, "#{check.shellescape} -s #{sigdir.shellescape}#{deps} -t #{targets.shellescape} -d #{double} " \
                         "-o #{prefix.shellescape} -c #{calls.shellescape} -- bash -c #{config.test_cmd.shellescape}",
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
      uncalled = File.exist?(calls) ? uncalled(sig, calls) : nil
      { plain: plain, checked: checked, checks: checks, errors: errors, uncalled: uncalled,
        errors_file: "#{prefix}.errors.tsv", logs: [plain_log, checked_log] }
    end

    # Declared methods the run never called (coverage_report.rb per file).
    def uncalled(sig, calls)
      script = File.join(LIBEXEC, "coverage_report.rb")
      sig_files(sig).flat_map do |f|
        out = IO.popen([RbConfig.ruby, script, f, calls], err: File::NULL, &:read)
        out.lines(chomp: true).reject { |l| l.end_with?("(private)") }
      end.uniq
    end

    # Proves the runtime checks really cover each declaration: runs `cmd`
    # under rbs/test with a copy of the signatures where every return type
    # (and attr type) is `bot`, so every checked call must fail. Declared
    # methods that never fail were not checked by this run: never called,
    # inherited rather than defined by the class (rbs/test only hooks a
    # class's own methods), or hidden from the hook. Returns
    # { checked: [...], unchecked: [...], skipped: [...] }.
    def live(config, sig, cmd)
      dir = File.join(config.out, "live")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      manifest = File.join(sigdir, "manifest.yaml")
      FileUtils.cp(manifest, File.join(dir, "sig")) if File.exist?(manifest)
      sig_files(sig).each_with_index do |f, i|
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
      rbs_all = RbsReader.read_files(sig_files(sig))
      reopened = rbs_all.classes.keys.reject { |c| config.in_ns?("#{c}#x") }
      targets = (config.ns.flat_map { |n| [n, "#{n}::*"] } + reopened).join(",")
      prefix = File.join(dir, "run")
      src = Sources::Base.new(config)
      check = File.join(LIBEXEC, "rbs_check.sh")
      double = cmd.include?("rspec") ? "rspec" : "minitest"
      only = rbs_all.methods.keys.select { |k| reopened.include?(GemTypes.split_key(k).first) }
      env = only.empty? ? config.env : config.env.merge("RBS_TEST_ONLY_METHODS" => only.join(","))
      src.sh(env, "#{check.shellescape} -s #{File.join(dir, 'sig').shellescape}#{dep_sig_args(config, sig)} -t #{targets.shellescape} " \
                         "-d #{double} -o #{prefix.shellescape} -- bash -c #{cmd.shellescape}",
             chdir: config.repo, log: File.join(dir, "run.log"))
      failed = File.exist?("#{prefix}.errors.tsv") ? File.readlines("#{prefix}.errors.tsv", encoding: "UTF-8").filter_map { |l| l[/\t\[(.+?)\] \w+Error/, 1] }.uniq : []
      rbs = RbsReader.read_files(sig_files(sig))
      keys = rbs.methods.reject { |_, v| v.all? { |x| x.start_with?("(alias of") } }.keys
      skipped, keys = keys.partition { |k| k.end_with?("#initialize") }
      # `def self?.m` (module_function): the instance copy is private and
      # normally not called; the singleton one stands for both.
      keys.reject! do |k|
        owner, sep, name = GemTypes.split_key(k)
        sep == "#" && keys.include?("#{owner}.#{name}") && !failed.include?(k)
      end
      checked, unchecked = keys.partition { |k| failed.include?(k) }
      { checked: checked.sort, unchecked: unchecked.sort, skipped: skipped.sort, log: File.join(dir, "run.log") }
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
      rbs = RbsReader.read_files(sig_files(sig), include_private: true)
      out = []
      DefIndex.new(config.lib_paths).each do |d|
        sigs = rbs.methods[d[:key]] || (d[:key].end_with?("#initialize") ? rbs.methods[d[:key].sub("#initialize", ".new")] : nil)
        next unless sigs

        hash_param = d[:params].find { |p| p[:kind] == "opt" && p[:hash_default] }
        if hash_param && d[:params].none? { |p| %w[req rest keyreq key keyrest].include?(p[:kind]) }
          types = sigs.reject { |x| x.start_with?("(alias of") }.filter_map { |x| RBS::Parser.parse_method_type(x).type rescue nil }
          positional = types.any? { |f| f.respond_to?(:required_positionals) && (f.required_positionals + f.optional_positionals).any? || (f.respond_to?(:rest_positionals) && f.rest_positionals) }
          keywords = types.any? { |f| f.respond_to?(:optional_keywords) && (f.optional_keywords.any? || f.required_keywords.any? || f.rest_keywords) }
          if keywords && !positional
            out << [d[:key], "takes `#{hash_param[:name]} = {}` positionally but the RBS only accepts keywords; add `| (Hash[Symbol, untyped] #{hash_param[:name]}) -> ...`"]
          end
        end
        unless d[:legacy_consts].empty?
          out << [d[:key], "refers to #{d[:legacy_consts].join(', ')} (removed in Ruby 3.2): check whether every call raises NameError"]
        end
      end
      out.uniq
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
        return obs.start_with?("singleton(") && names(member[10..-2], owner).any? { |n| obs == "singleton(#{n})" } ||
               obs.start_with?("singleton(") # subclasses: not tracked, accept
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
    # M failures, E errors" (Minitest / test-unit) lines in a log.
    def test_counts(log)
      total = 0
      failed = 0
      unit = nil
      log.scan(/(\d+) examples?, (\d+) failures?/) { total += $1.to_i; failed += $2.to_i; unit = "examples" }
      log.scan(/(\d+) (?:runs|tests), \d+ assertions, (\d+) failures, (\d+) errors/) do
        total += $1.to_i; failed += $2.to_i + $3.to_i; unit ||= "runs"
      end
      { total: total, failed: failed, unit: unit || "tests" }
    end

    # " -s <dir>" for the RBS of the gem's runtime dependencies that the
    # collection has (gems/<dep>/<version>, the newest version allowed by
    # the dependency, else the newest), so signatures can refer to them
    # (faraday_middleware's classes inherit from Faraday::Middleware).
    def dep_sig_args(config, sig)
      gems_dir = File.expand_path(sig).split(File::SEPARATOR).then do |parts|
        i = parts.rindex("gems") or return ""
        parts[0..i].join(File::SEPARATOR)
      end
      pkg = Dir[File.join(File.dirname(config.out), "*.gem")].first or return ""
      require "rubygems/package"
      spec = Gem::Package.new(pkg).spec
      own = File.expand_path(File.directory?(sig) ? sig : File.dirname(sig))
      spec.runtime_dependencies.filter_map do |dep|
        versions = Dir[File.join(gems_dir, dep.name, "*")].select { |d| File.directory?(d) && File.basename(d).match?(/\A\d/) }
        next if versions.empty?

        sorted = versions.sort_by { |d| Gem::Version.new(File.basename(d)) }
        best = sorted.reverse.find { |d| dep.requirement.satisfied_by?(Gem::Version.new("#{File.basename(d)}.0")) } || sorted.last
        next if File.expand_path(best) == own

        " -s #{best.shellescape}"
      end.join
    rescue StandardError
      ""
    end

    def sig_files(sig)
      File.directory?(sig) ? Dir[File.join(sig, "**", "*.rbs")] : [sig]
    end
  end
end
