# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "json"

module GemTypes
  # `gem-types run`: prepare, install, sanity-check the tests, find the
  # namespace, collect and draft for several gems, in parallel. A gem that
  # fails a step is skipped with the reason; the others go on.
  class Batch
    Result = Struct.new(:gem, :workdir, :status, :step, :reason, :tests, :ns, :methods, :version, :worktree,
                        :test_cmd, keyword_init: true)

    STEPS = %w[prepare install tests namespace collect draft].freeze

    # Signs of RSpec 2 era specs failing on RSpec 3.
    RSPEC2 = /undefined method [`']stub!'|any_number_of_times|:stdlib is not supported|undefined method [`']mock' for|and_return\(\)/

    # worktrees: a gem_rbs_collection checkout; for each gem that gets a
    # draft, a worktree on branch add-<gem> is created next to the workdirs
    # (base/wt/<gem>) from `ref`.
    def initialize(gems, base:, jobs: 2, exe: File.join(ROOT, "exe", "gem-types"), worktrees: nil, ref: "HEAD")
      @worktrees = worktrees && File.expand_path(worktrees)
      @ref = ref
      @gems = gems
      @base = File.expand_path(base)
      @jobs = [jobs, 1].max
      @exe = exe
      @lock = Mutex.new
    end

    def run
      queue = Queue.new
      @gems.each { |g| queue << g }
      results = []
      Array.new([@jobs, @gems.size].min) do
        Thread.new do
          while (gem = (queue.pop(true) rescue nil))
            r = one(gem)
            @lock.synchronize do
              results << r
              warn format("%-24s %-7s %s", gem, r.status, r.status == "ok" ? "#{r.methods} methods drafted" : "#{r.step}: #{r.reason}")
            end
          end
        end
      end.each(&:join)
      results.sort_by { |r| @gems.index(r.gem) }
    end

    def summary(results)
      out = ["| gem | status | tests | namespace | methods | note |", "|---|---|---|---|---|---|"]
      results.each do |r|
        note = r.status == "ok" ? "#{r.workdir}/report.md" : "#{r.step}: #{r.reason}"
        out << "| #{r.gem} | #{r.status} | #{r.tests || '-'} | #{(r.ns || []).join(', ')} | #{r.methods || '-'} | #{note} |"
      end
      out.join("\n")
    end

    private

    def one(gem)
      w = File.join(@base, gem)
      logs = File.join(w, "run")
      FileUtils.mkdir_p(logs)
      r = Result.new(gem: gem, workdir: w, status: "failed")
      step = lambda do |name, ok, reason|
        r.step = name
        r.reason = reason unless ok
        ok
      end

      return r unless step.("prepare", sh({}, "#{File.join(LIBEXEC, 'prepare_gem.sh').shellescape} #{gem.shellescape} '' #{w.shellescape}",
                                          @base, File.join(logs, "prepare.log")) && Dir.exist?(File.join(w, "repo")),
                            "no upstream checkout (see run/prepare.log)")

      env = { "BUNDLE_GEMFILE" => File.join(w, "env", "Gemfile"), "GEM_HOME" => File.join(w, "gemhome"),
              "GEM_PATH" => File.join(w, "gemhome") }
      return r unless step.("install", install(w, env, logs),
                            "bundle install failed (see run/install.log; edit env/Gemfile and rerun)")

      test_cmd = File.read(File.join(w, "test_cmd")).strip if File.exist?(File.join(w, "test_cmd"))
      return r unless step.("tests", test_cmd, "no test command guessed")

      r.test_cmd = test_cmd
      r.version = Dir[File.join(w, "*.gem")].map { |f| File.basename(f, ".gem")[/-(\d+\.\d+)[^-]*\z/, 1] }.first
      counts, env = run_tests_with_fixes(w, env, test_cmd, logs)
      r.tests = "#{counts[:total]} #{counts[:unit]}, #{counts[:failed]} failing"
      return r unless step.("tests", counts[:total].positive?, "the tests did not run (see run/tests.log)")
      return r unless step.("tests", counts[:failed] * 2 <= counts[:total], "most tests fail without tooling (#{r.tests})")

      req, ns = namespace(gem, w, env)
      r.ns = ns
      return r unless step.("namespace", !ns.empty?, "no constants defined by requiring #{req || gem}")

      ok = sh({}, "#{RbConfig.ruby.shellescape} #{@exe.shellescape} collect --workdir #{w.shellescape} " \
                  "--ns #{ns.join(',').shellescape} --require #{req.shellescape}",
              @base, File.join(logs, "collect.log"))
      return r unless step.("collect", ok, "see run/collect.log")

      ok = sh({}, "#{RbConfig.ruby.shellescape} #{@exe.shellescape} draft --workdir #{w.shellescape}",
              @base, File.join(logs, "draft.log"))
      draft = File.join(w, "draft.rbs")
      return r unless step.("draft", ok && File.exist?(draft), "see run/draft.log")

      r.methods = File.readlines(draft).count { |l| l.match?(/\A\s+(def|attr_)/) }
      r.worktree = worktree(gem) if @worktrees
      r.status = "ok"
      r.step = nil
      r
    rescue StandardError => e
      r.reason = "#{e.class}: #{e.message}"
      r
    end

    # Runs the tests; when the log shows a known environment problem, fixes
    # it and runs again (up to 4 times), keeping a fix only if more tests
    # run or fewer fail:
    #   RSpec 2 era specs         -> libexec/rspec2_compat.rb in RUBYOPT
    #   uninitialized MiniTest    -> libexec/minitest_compat.rb (minitest 6 dropped it)
    #   obj.must_equal on minitest 6 -> pin minitest ~> 5.0
    #   cannot load such file -- x / command not found: x
    #                             -> add gem x to env/Gemfile and install
    # Environment fixes are saved in gem-types.json for later commands.
    def run_tests_with_fixes(w, env, test_cmd, logs)
      log = File.join(logs, "tests.log")
      sh(env, test_cmd, File.join(w, "repo"), log)
      text = File.read(log, encoding: "UTF-8")
      counts = Verify.test_counts(text)
      tried = []
      4.times do |i|
        break if counts[:total].positive? && counts[:failed].zero?

        fix = next_fix(text, env, test_cmd, tried) or break
        tried << fix[:name]
        gemfile = File.join(w, "env", "Gemfile")
        before = File.read(gemfile)
        new_env = env.merge(fix[:env] || {})
        if fix[:gem]
          kept = before.lines.reject { |l| l.match?(/\A\s*gem\s+["']#{Regexp.escape(fix[:gem])}["']/) }.join
          req = fix[:req] ? ", #{fix[:req].dump}" : ""
          File.write(gemfile, kept + "gem #{fix[:gem].dump}#{req} # added by gem-types run: the tests need it\n")
          unless sh(new_env, "bundle install --quiet", File.join(w, "env"), File.join(logs, "install-#{fix[:gem]}.log"))
            File.write(gemfile, before)
            next
          end
        end
        log2 = File.join(logs, "tests-fix#{i + 1}-#{fix[:name].tr('^a-zA-Z0-9_-', '_')}.log")
        sh(new_env, test_cmd, File.join(w, "repo"), log2)
        t2 = File.read(log2, encoding: "UTF-8")
        c2 = Verify.test_counts(t2)
        if c2[:total] > counts[:total] || (c2[:total] == counts[:total] && c2[:failed] < counts[:failed]) ||
           (c2[:total] == counts[:total] && t2 != text && fix[:gem])
          counts, text, env = c2, t2, new_env
          File.write(File.join(w, "gem-types.json"), JSON.pretty_generate(env: env, test_cmd: test_cmd))
        elsif fix[:gem]
          File.write(gemfile, before)
        end
      end
      [counts, env]
    end

    def next_fix(text, env, test_cmd, tried)
      cands = []
      if test_cmd.include?("rspec") && text.match?(RSPEC2)
        rubyopt = [env["RUBYOPT"], "-r#{File.join(LIBEXEC, 'rspec2_compat.rb')}"].compact.join(" ")
        cands << { name: "rspec2", env: { "RUBYOPT" => rubyopt } }
      end
      if text.match?(/uninitialized constant MiniTest\b/)
        rubyopt = [env["RUBYOPT"], "-r#{File.join(LIBEXEC, 'minitest_compat.rb')}"].compact.join(" ")
        cands << { name: "minitest_compat", env: { "RUBYOPT" => rubyopt, "MT_COMPAT" => "1" } }
      end
      # minitest 6 removed the expectations on Object (obj.must_equal ...).
      cands << { name: "minitest5", gem: "minitest", req: "~> 5.0" } if text.match?(/undefined method [`'](must|wont)_\w+'/)
      text.scan(/cannot load such file -- ([\w\-\/]+)/).flatten.uniq.each do |f|
        next if f.start_with?(".", "/")

        cands << { name: "gem-#{f.split('/').first}", gem: f.split("/").first }
      end
      text.scan(/command not found: ([\w\-]+)/).flatten.uniq.each { |c| cands << { name: "gem-#{c}", gem: c } }
      cands.find { |c| !tried.include?(c[:name]) }
    end

    # bundle install; on failure, drop the repo-Gemfile gems the log names
    # (the package's own dependencies stay) and try once more.
    def install(w, env, logs)
      gemfile = File.join(w, "env", "Gemfile")
      log = File.join(logs, "install.log")
      return true if sh(env, "bundle install --quiet", File.join(w, "env"), log)

      text = File.read(log, encoding: "UTF-8")
      lines = File.readlines(gemfile)
      start = lines.index { |l| l.start_with?("# From ") } or return false
      stop = lines.index { |l| l.start_with?("# For gem-types") } || lines.size
      dropped = []
      (start...stop).each do |i|
        name = lines[i][/\Agem "([^"]+)"/, 1] or next
        next unless text.match?(/\b#{Regexp.escape(name)}\b/)

        dropped << name
        lines[i] = "# #{lines[i].chomp}  # dropped: bundle install failed on it\n"
      end
      return false if dropped.empty?

      File.write(gemfile, lines.join)
      sh(env, "bundle install --quiet", File.join(w, "env"), File.join(logs, "install-retry.log"))
    end

    def worktree(gem)
      dir = File.join(@base, "wt", gem)
      return dir if Dir.exist?(dir)

      branch = "add-#{gem}"
      exists = system("git", "-C", @worktrees, "rev-parse", "--verify", "-q", branch, out: File::NULL, err: File::NULL)
      args = exists ? [dir, branch] : ["-b", branch, dir, @ref]
      @lock.synchronize { system("git", "-C", @worktrees, "worktree", "add", "-q", *args, out: File::NULL, err: File::NULL) }
      Dir.exist?(dir) ? dir : nil
    end

    # Arguments for the gem-rbs-author workflow, for the gems that got a draft.
    def workflow_args(results)
      items = results.select { |r| r.status == "ok" }.map do |r|
        { gem: r.gem, ver: r.version, ns: r.ns.flat_map { |n| [n, "#{n}::*"] }.join(","),
          workdir: r.workdir, worktree: r.worktree, test_cmd: r.test_cmd }.compact
      end
      { tools: ROOT, items: items }
    end
    public :workflow_args

    # What to require (a lib file named like the gem) and the top-level
    # constants that requiring it defines from the gem's own lib.
    def namespace(gem, w, env)
      lib = File.join(w, "repo", "lib")
      cands = [gem, gem.tr("-", "/"), gem.tr("-", "_")].uniq
      req = cands.find { |c| File.exist?(File.join(lib, "#{c}.rb")) } ||
            Dir[File.join(lib, "*.rb")].map { |f| File.basename(f, ".rb") }.first
      return [nil, []] unless req

      script = <<~RUBY
        before = Object.constants
        require #{req.dump}
        lib = #{File.join(lib, '').dump}
        puts (Object.constants - before).select { |c|
          (Object.const_source_location(c.to_s) || []).first.to_s.start_with?(lib)
        }
      RUBY
      out = File.join(w, "run", "namespace.txt")
      sh(env.merge("RUBYOPT" => "-I#{lib}"), "bundle exec ruby -e #{script.shellescape} > #{out.shellescape}",
         File.join(w, "repo"), File.join(w, "run", "namespace.log"))
      [req, File.exist?(out) ? File.readlines(out, chomp: true).reject(&:empty?).sort : []]
    end

    def sh(env, cmd, chdir, log)
      base = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
      base = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }.merge(base) unless base["LANG"].to_s.include?("UTF-8")
      system(base.merge(env), "bash", "-c", cmd, chdir: chdir, out: log, err: %i[child out], unsetenv_others: true)
    end
  end
end
