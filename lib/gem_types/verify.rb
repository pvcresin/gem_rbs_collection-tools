# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "shellwords"

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
        problems.each { |p| puts "  #{p}" }
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

        via = sep == "#" && mod.instance_methods.include?(:respond_to_missing?) ? " (may be handled by method_missing)" : ""
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
      src.sh(config.env, "#{check.shellescape} -s #{sigdir.shellescape} -t #{targets.shellescape} -d #{double} " \
                         "-o #{prefix.shellescape} -- #{config.test_cmd}",
             chdir: config.repo, log: checked_log)
      plain = test_counts(File.read(plain_log, encoding: "UTF-8"))
      checked = test_counts(File.read(checked_log, encoding: "UTF-8"))
      checks = File.exist?("#{prefix}.checked.tsv") ? File.readlines("#{prefix}.checked.tsv").sum { _1.to_i } : 0
      errors = File.exist?("#{prefix}.errors.tsv") ? File.readlines("#{prefix}.errors.tsv", chomp: true, encoding: "UTF-8").reject(&:empty?) : []
      { plain: plain, checked: checked, checks: checks, errors: errors,
        errors_file: "#{prefix}.errors.tsv", logs: [plain_log, checked_log] }
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

    def sig_files(sig)
      File.directory?(sig) ? Dir[File.join(sig, "**", "*.rbs")] : [sig]
    end
  end
end
