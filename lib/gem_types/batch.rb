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

    # A test run that takes longer than this (seconds) is stopped: some
    # suites hang on a server or a prompt without their usual environment.

    # Required files whose gem is not named after the path.
    REQUIRE_GEMS = {
      "test/unit" => "test-unit", "active_support" => "activesupport", "active_record" => "activerecord",
      "active_model" => "activemodel", "action_controller" => "actionpack", "action_dispatch" => "actionpack",
      "action_view" => "actionview", "rack/test" => "rack-test", "minitest/reporters" => "minitest-reporters",
      "rspec/its" => "rspec-its", "rspec/collection_matchers" => "rspec-collection_matchers",
      "mocha/api" => "mocha", "mocha/minitest" => "mocha", "mocha/setup" => "mocha", "webmock/rspec" => "webmock",
      "webmock/minitest" => "webmock", "shoulda/context" => "shoulda-context", "test/unit/rr" => "test-unit-rr",
      "racc/parser" => "racc", "rake/extensiontask" => "rake-compiler", "rake/javaextensiontask" => "rake-compiler",
      # the suite's own helpers, not gems
      "spec_helper" => nil, "test_helper" => nil, "helper" => nil
    }.freeze

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
      r.version = prepared_version(gem, w)
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
    # it and runs again (up to 4 times), keeping a fix only if it helps
    # (see better?):
    #   RSpec 2 era specs         -> libexec/rspec2_compat.rb in RUBYOPT
    #   uninitialized MiniTest    -> libexec/minitest_compat.rb (minitest 6 dropped it)
    #   obj.must_equal on minitest 6 -> pin minitest ~> 5.0
    #   cannot load such file -- x / command not found: x
    #                             -> add gem x to env/Gemfile and install
    #   cannot load the gem's own extension -> bundle exec rake compile
    # Environment fixes are saved in gem-types.json for later commands.
    def run_tests_with_fixes(w, env, test_cmd, logs)
      log = File.join(logs, "tests.log")
      root = gem_root(w)
      ok = sh(env, timed(test_cmd), root, log)
      kept_log = log
      text = File.read(log, encoding: "UTF-8")
      counts = Verify.test_counts(text)
      tried = []
      # Up to 4 test runs; a gem that does not install (a guessed name such
      # as racc-parser for racc/parser) costs no run.
      runs = 0
      12.times do
        break if runs >= 4 || (counts[:total].positive? && counts[:failed].zero?)

        gemfile = File.join(w, "env", "Gemfile")
        before = File.read(gemfile)
        fix = next_fix(text, env, test_cmd, tried, root: root, gemfile: before) or break
        tried << fix[:name]
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
        if fix[:pre] && !sh(new_env, fix[:pre], root, File.join(logs, "pre-#{fix[:name]}.log"))
          next
        end
        runs += 1
        log2 = File.join(logs, "tests-fix#{runs}-#{fix[:name].tr('^a-zA-Z0-9_-', '_')}.log")
        ok2 = sh(new_env, timed(test_cmd), root, log2)
        t2 = File.read(log2, encoding: "UTF-8")
        c2 = Verify.test_counts(t2)
        if better?(counts, c2, changed: t2 != text && !fix[:gem].nil?)
          counts, text, env, ok, kept_log = c2, t2, new_env, ok2, log2
          File.write(File.join(w, "gem-types.json"), JSON.pretty_generate(repo: root, env: env, test_cmd: test_cmd))
        elsif fix[:gem]
          File.write(gemfile, before)
        end
      end
      save_plain_run(w, root, env, test_cmd, kept_log, ok)
      [counts, env]
    end

    # Records the kept run as the workdir's plain test run, which `verify`
    # reuses while the inputs are unchanged (see PlainRun).
    def save_plain_run(w, root, env, test_cmd, log, ok)
      cfg = Config.new(repo: root, lib_dirs: ["lib"], test_dirs: %w[test spec], ns: [], requires: [],
                       test_cmd: test_cmd, env: env.transform_keys(&:to_s), out: File.join(w, "evidence"))
      PlainRun.new(cfg).store(log, ok)
    rescue StandardError => e
      warn "#{File.basename(w)}: could not record the plain run (#{e.message})"
    end

    # Whether a run with a fix (c2) is better than the run without (c1).
    # When no test ran before: tests run now, or (a gem was added) the
    # output changed, e.g. to the next missing file. Otherwise failures must
    # not increase nor passes decrease, and more tests run, fewer fail, or
    # (a gem was added) the output changed.
    def better?(c1, c2, changed: false)
      return c2[:total].positive? || (c2[:total].zero? && changed) if c1[:total].zero?
      return false if c2[:failed] > c1[:failed] || c2[:total] - c2[:failed] < c1[:total] - c1[:failed]

      c2[:total] > c1[:total] || c2[:failed] < c1[:failed] || changed
    end

    # The next environment fix to try for a test log, or nil. root is the
    # gem's checkout (files the tests require from it are not gems);
    # gemfile the env/Gemfile text (gems already there are not rewritten,
    # except to pin minitest 5).
    def next_fix(text, env, test_cmd, tried, root: nil, gemfile: "")
      cands = []
      # A C extension that was never built: the tests cannot load its .so.
      if root && (ext = compile_fix(text, root, gemfile))
        cands << ext
      end
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
      in_gemfile = ->(g) { gemfile.match?(/^\s*gem\s+["']#{Regexp.escape(g)}["']/) }
      add = ->(g) { cands << { name: "gem-#{g}", gem: g } unless in_gemfile.(g) || cands.any? { _1[:gem] == g } }
      text.scan(/cannot load such file -- ([\w\-\/]+)/).flatten.uniq.each do |f|
        next if f.start_with?(".", "/")
        next if root && %w[lib test spec].any? { |d| File.exist?(File.join(root, d, "#{f}.rb")) || File.directory?(File.join(root, d, f)) }

        gem_names_for(f).each(&add)
      end
      text.scan(/command not found: ([\w\-]+)/).flatten.uniq.each(&add)
      # bundle exec rake with no rake in the Gemfile (kramdown).
      text.scan(/can't find executable ([\w\-]+) for gem ([\w\-]+)/).map(&:last).uniq.each(&add)
      cands.find { |c| !tried.include?(c[:name]) }
    end

    # { name: "compile", pre: "bundle exec rake compile" } when the log
    # cannot load one of the gem's own extensions (ext/**/extconf.rb names
    # them; unf_ext's tests fail with "cannot load such file -- 3.3/unf_ext.so").
    def compile_fix(text, root, gemfile = "")
      # The extension's name: its directory, or what extconf.rb passes to
      # create_makefile (nio4r's ext/nio4r builds nio4r_ext).
      exts = Dir[File.join(root, "ext", "**", "extconf.rb")].flat_map do |f|
        made = File.read(f, encoding: "UTF-8").scrub.scan(/create_makefile\(?\s*["']([^"']+)["']/).flatten.map { File.basename(_1) }
        [File.basename(File.dirname(f)), *made]
      end
      return if exts.empty?

      missing = text.scan(/cannot load such file -- (\S+)/).flatten.map { File.basename(_1, ".*") }
      return unless missing.intersect?(exts)

      # Without the Rakefile when that fails (nio4r's needs rubocop): build
      # each extension with extconf.rb and make, and copy it where
      # create_makefile's name puts it under lib/.
      direct = Dir[File.join(root, "ext", "**", "extconf.rb")].map do |f|
        dir = File.dirname(f).delete_prefix("#{root}/")
        made = File.read(f, encoding: "UTF-8").scrub[/create_makefile\(?\s*["']([^"']+)["']/, 1] || File.basename(dir)
        "(cd #{dir.shellescape} && bundle exec ruby extconf.rb && make) && mkdir -p #{File.join('lib', File.dirname(made)).shellescape} && " \
          "cp #{File.join(dir, "#{File.basename(made)}.#{RbConfig::CONFIG['DLEXT']}").shellescape} #{File.join('lib', File.dirname(made)).shellescape}/"
      end
      fix = { name: "compile", pre: "bundle exec rake compile || (#{direct.join(' && ')})" }
      # Rake::ExtensionTask comes from rake-compiler, which the gem's own
      # Gemfile has but env/Gemfile may not (nio4r).
      tasks = Dir[File.join(root, "{Rakefile,rakelib/*.rake}")].map { File.read(_1, encoding: "UTF-8").scrub }.join("\n")
      fix[:gem] = "rake-compiler" if tasks.include?("rake/extensiontask") && !gemfile.match?(/^\s*gem\s+["']rake-compiler["']/)
      fix
    end

    # Gems that may provide a required path, most likely first:
    # minitest/reporters -> minitest-reporters, minitest; test/unit -> test-unit.
    def gem_names_for(path)
      return [REQUIRE_GEMS[path]].compact if REQUIRE_GEMS.key?(path)

      parts = path.split("/")
      names = parts.size.downto(1).map { |n| parts.first(n).join("-") }
      names.insert(1, parts.join("_")) if parts.size > 1
      names.uniq
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

      # A gem already in the collection is improved on update-<gem>
      # (the repository's convention), a new one added on add-<gem>.
      branch = "#{from_version(gem) ? 'update' : 'add'}-#{gem}"
      exists = system("git", "-C", @worktrees, "rev-parse", "--verify", "-q", branch, out: File::NULL, err: File::NULL)
      # An existing branch is reused only while it builds on @ref. One left
      # from an earlier PR (squash-merged upstream, so not an ancestor of
      # @ref) is restarted from @ref: update-builder once carried the merged
      # #1204 commit into the next PR.
      if exists && !system("git", "-C", @worktrees, "merge-base", "--is-ancestor", @ref, branch, out: File::NULL, err: File::NULL)
        old = IO.popen(["git", "-C", @worktrees, "rev-parse", "--short", branch], &:read).strip
        warn "#{gem}: branch #{branch} (#{old}) does not build on #{@ref}; restarting it from #{@ref}"
        exists = false
      end
      args = exists ? [dir, branch] : ["-B", branch, dir, @ref]
      @lock.synchronize { system("git", "-C", @worktrees, "worktree", "add", "-q", *args, out: File::NULL, err: File::NULL) }
      Dir.exist?(dir) ? dir : nil
    end

    # The newest version directory of gems/<gem> at the worktree ref, or
    # nil for a gem not in the collection yet.
    def from_version(gem)
      return nil unless @worktrees

      @from ||= {}
      return @from[gem] if @from.key?(gem)

      out = IO.popen(["git", "-C", @worktrees, "ls-tree", "--name-only", @ref, "gems/#{gem}/"], err: File::NULL, &:read).to_s
      vers = out.split("\n").map { File.basename(_1) }.grep(/\A\d+(\.\d+)*\z/)
      @from[gem] = vers.max_by { Gem::Version.new(_1) }
    end

    # Arguments for the gem-rbs-author workflow, for the gems that got a
    # draft. `from`: the existing version directory to improve (the
    # workflow's improvement mode).
    def workflow_args(results)
      items = results.select { |r| r.status == "ok" }.map do |r|
        # Version directories are major.minor (gems/foo/1.2).
        { gem: r.gem, ver: r.version.to_s[/\A\d+\.\d+/] || r.version, ns: r.ns.flat_map { |n| [n, "#{n}::*"] }.join(","),
          workdir: r.workdir, worktree: r.worktree, test_cmd: r.test_cmd, from: from_version(r.gem) }.compact
      end
      { tools: ROOT, items: items }
    end
    public :workflow_args

    # The gem's root in the checkout: repo/, or repo/<subdir> for a gem in
    # a monorepo (prepare_gem.sh writes repo_dir).
    def gem_root(w)
      f = File.join(w, "repo_dir")
      dir = File.read(f).strip if File.exist?(f)
      dir && !dir.empty? && Dir.exist?(dir) ? dir : File.join(w, "repo")
    end

    def prepared_version(gem, w)
      f = File.join(w, "version")
      return File.read(f).strip if File.exist?(f)

      Dir[File.join(w, "#{gem}-*.gem")].map { |p| File.basename(p, ".gem").delete_prefix("#{gem}-") }
                                       .max_by { |v| Gem::Version.new(v[/\A[\d.]+/] || "0") }
    end

    def timed(cmd) = GemTypes.timed(cmd)

    # What to require (a lib file named like the gem) and the outermost
    # modules and top-level constants that requiring it defines from the
    # gem's own lib: Net::HTTP::Persistent for net-http-persistent (Net and
    # Net::HTTP existed before), Rack::Protection for rack-protection.
    def namespace(gem, w, env)
      root = gem_root(w)
      lib = File.join(root, "lib")
      # Shorter paths too: google-cloud-core.rb only exists for auto-loading
      # and defines nothing; google/cloud.rb has the code.
      parts = gem.split("-")
      cands = [gem, gem.tr("-", "/"), gem.tr("-", "_"), *(parts.size - 1).downto(1).map { |n| parts.first(n).join("/") }].uniq
      reqs = cands.select { |c| File.exist?(File.join(lib, "#{c}.rb")) }
      reqs = Dir[File.join(lib, "*.rb")].map { |f| File.basename(f, ".rb") }.first(1) if reqs.empty?
      return [nil, []] if reqs.empty?

      result = nil
      reqs.each do |req|
        out = File.join(w, "run", "namespace.txt")
        deps_out = File.join(w, "run", "requires.txt")
        FileUtils.rm_f(deps_out)
        sh(env.merge("RUBYOPT" => "-I#{lib}"),
           "bundle exec ruby -e #{namespace_script(req, lib, gem, runtime_deps(w), deps_out).shellescape} > #{out.shellescape}",
           root, File.join(w, "run", "namespace.log"))
        # Requires that loaded (dependencies first: faraday-net_http's lib
        # needs Faraday loaded), for `collect --require`.
        loaded = File.exist?(deps_out) ? File.readlines(deps_out, chomp: true).reject(&:empty?) : []
        result = [(loaded + [req]).uniq.join(","), File.exist?(out) ? File.readlines(out, chomp: true).reject(&:empty?).sort : []]
        break unless result[1].empty?
      end
      result
    end

    def runtime_deps(w)
      require "rubygems/package"
      pkg = Dir[File.join(w, "*.gem")].first or return []
      Gem::Package.new(pkg).spec.runtime_dependencies.map(&:name)
    rescue StandardError
      []
    end

    # Ruby that prints those names. A constant defined by the gem's own
    # native extension (FFI, from ffi_c.so of the installed ffi gem) counts
    # as the gem's when the gem's lib adds to it.
    def namespace_script(req, lib, gem = nil, deps = [], deps_out = nil)
      native = gem ? %r{/#{Regexp.escape(gem)}-\d[^/]*/.*\.(so|bundle|dll)\z} : /(?!)/
      <<~RUBY
        name_of = Module.instance_method(:name)
        before_consts = Object.constants
        before = {}
        ObjectSpace.each_object(Module) { |m| before[m.__id__] = true }
        # The gem's runtime dependencies first, as an application would
        # have them loaded (taken after the snapshot: what they define is
        # filtered out below by where it was defined).
        loaded = []
        #{deps.inspect}.each do |d|
          [d, d.tr("-", "/")].uniq.each do |r|
            begin
              require r
              loaded << r
              break
            rescue LoadError, StandardError
              next
            end
          end
        end
        # A plugin gem (faraday-net_http, rack-*) may need its host library
        # loaded first without depending on it: retry after requiring the
        # gem name's first part.
        begin
          require #{req.dump}
        rescue NameError, NoMethodError, LoadError
          host = #{gem.to_s.split(/[-_]/).first.to_s.dump}
          raise if host.empty? || loaded.include?(host)
          require host
          loaded << host
          require #{req.dump}
        end
        File.write(#{deps_out.to_s.dump}, loaded.join("\n")) unless #{deps_out.to_s.dump}.empty?
        lib = #{File.join(lib, '').dump}
        native = Regexp.new(#{native.source.dump})
        loc_of = lambda do |mod, c|
          (mod.const_source_location(c.to_s) rescue nil).to_a.first.to_s
        end
        in_lib = lambda do |n|
          loc = loc_of.(Object, n)
          next true if loc.start_with?(lib)
          next false unless loc.match?(native)

          mod = Object.const_get(n)
          mod.is_a?(Module) && mod.constants(false).any? { |c| loc_of.(mod, c).start_with?(lib) }
        rescue StandardError, NameError, LoadError
          false
        end
        names = (Object.constants - before_consts).map(&:to_s)
        ObjectSpace.each_object(Module) do |m|
          next if before[m.__id__]

          n = name_of.bind_call(m)
          names << n if n && n.match?(/\\A[A-Z]\\w*(::[A-Z]\\w*)*\\z/)
        end
        # A namespace the gem shares with others (Rack, when rack-protection's
        # lib happens to open it first) holds constants defined elsewhere.
        shared = lambda do |n|
          mod = Object.const_get(n)
          mod.is_a?(Module) && mod.constants(false).any? do |c|
            loc = loc_of.(mod, c)
            !loc.empty? && !loc.start_with?(lib) && !loc.match?(native)
          end
        rescue StandardError, NameError, LoadError
          false
        end
        # A module whose constant a dependency defined first (mime-types-data
        # defines MIME::Types::Data before mime-types loads) is still the
        # gem's when the gem's lib defines its methods.
        own_methods = lambda do |n|
          mod = Object.const_get(n)
          next false unless mod.is_a?(Module)

          # Most of its methods, not a few added to a library module
          # (rake's FileUtils#sh, httparty's Net::HTTPHeader additions).
          locs = (mod.instance_methods(false) + mod.private_instance_methods(false)).map { |m| mod.instance_method(m).source_location } +
                 mod.singleton_methods(false).map { |m| mod.method(m).source_location }
          mine = locs.count { |l| l.to_a.first.to_s.start_with?(lib) }
          mine.positive? && mine * 2 >= locs.size
        rescue StandardError, NameError, LoadError
          false
        end
        names = names.uniq.select { |n| in_lib.(n) || own_methods.(n) }.reject { |n| shared.(n) && !own_methods.(n) }
        puts names.reject { |n| names.any? { |o| n.start_with?("\#{o}::") } }
      RUBY
    end

    def sh(env, cmd, chdir, log)
      base = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
      base = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }.merge(base) unless base["LANG"].to_s.include?("UTF-8")
      system(base.merge(env), "bash", "-c", cmd, chdir: chdir, out: log, err: %i[child out], unsetenv_others: true)
    end
  end
end
