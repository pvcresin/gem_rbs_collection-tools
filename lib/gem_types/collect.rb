# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module GemTypes
  # Digests of what a run depends on, so a run whose inputs did not change
  # can be reused instead of repeated.
  module Fingerprint
    # Directories that test runs write into: not inputs.
    SKIP = %w[.git tmp log coverage pkg node_modules .bundle].freeze
    # Files test runs write (RSpec's example status, logs).
    SKIP_FILES = %w[.rspec_status examples.txt *.log].freeze

    module_function

    # Content digest of the files under `paths` (files or directories).
    def files(paths)
      d = Digest::SHA256.new
      paths.select { |p| File.exist?(p) }.sort.each do |root|
        list = File.file?(root) ? [root] : Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
        list.sort.each do |f|
          next unless File.file?(f)
          next if (f.delete_prefix(root).split(File::SEPARATOR) & SKIP).any?
          next if SKIP_FILES.any? { |pat| File.fnmatch?(pat, File.basename(f)) }

          d << f << "\0" << Digest::SHA256.file(f).hexdigest << "\n"
        end
      end
      d.hexdigest
    end

    # The gem's code, its tests and the files at the top of the checkout
    # (Rakefile, gemspec, .rspec), plus the test environment's lock file.
    def repo(config)
      top = Dir.children(config.repo).map { |c| File.join(config.repo, c) }.select { |f| File.file?(f) }
      lock = config.env["BUNDLE_GEMFILE"] && "#{config.env['BUNDLE_GEMFILE']}.lock"
      files(config.lib_paths + config.test_paths + top + [lock].compact)
    end

    def of(*parts) = Digest::SHA256.hexdigest(JSON.generate(parts))
  end

  # The plain test run (the suite without any tooling) of a workdir, kept
  # in evidence/plain-run.json with the inputs it ran on. `run` records its
  # sanity run there and `verify` reuses it while the test command,
  # environment, code, tests and lock file are unchanged.
  # GEM_TYPES_FRESH=1 ignores it.
  class PlainRun
    def initialize(config)
      @config = config
      @file = File.join(config.out, "plain-run.json")
    end

    def key
      Fingerprint.of(@config.test_cmd, @config.env.sort, @config.repo, Fingerprint.repo(@config))
    end

    # { log: text, ok:, counts:, at: } for the saved run, or nil when there
    # is none or its inputs changed.
    def fetch
      return nil if ENV["GEM_TYPES_FRESH"] == "1" || !File.exist?(@file)

      saved = JSON.parse(File.read(@file), symbolize_names: true)
      return nil unless saved[:key] == key && File.exist?(saved[:log].to_s)

      text = File.read(saved[:log], encoding: "UTF-8")
      return nil unless Digest::SHA256.hexdigest(text) == saved[:log_digest]

      { log: text, path: saved[:log], ok: saved[:ok], counts: Verify.test_counts(text), at: saved[:at] }
    rescue JSON::ParserError
      nil
    end

    def store(log, ok)
      FileUtils.mkdir_p(File.dirname(@file))
      text = File.read(log, encoding: "UTF-8")
      File.write(@file, JSON.pretty_generate(key: key, log: File.expand_path(log), ok: ok ? true : false,
                                             log_digest: Digest::SHA256.hexdigest(text), at: Time.now.utc.to_s))
    end
  end

  # `gem-types collect`: runs the sources.
  #
  # - Static sources run in threads alongside the test runs, and are not
  #   run again while their inputs (code, tests, settings, tool versions)
  #   are unchanged (evidence/.cache; GEM_TYPES_FRESH=1 reruns them).
  # - By default tracepoint and lumitrace run the test suite at the same
  #   time, each with its own TMPDIR. A run that looks worse than the others
  #   or than the plain run (fewer tests, more failures, a failing exit) is
  #   repeated alone. `jobs: 1` runs them one at a time.
  # - rbs_trace runs only when tracepoint recorded nothing (or crashed
  #   early): with tracepoint's evidence it adds no method the draft keeps
  #   (its extra keys are private methods and inherited methods recorded on
  #   subclasses) and its extra "-> nil" overloads come from raising calls.
  #   Name it in `sources:` to run it anyway.
  class Collect
    DEFAULT_JOBS = 2
    # Seconds a static source may run (GEM_TYPES_STATIC_TIMEOUT overrides).
    STATIC_TIMEOUT = Integer(ENV.fetch("GEM_TYPES_STATIC_TIMEOUT", "120"))

    def initialize(config, sources: nil, jobs: nil, io: $stderr)
      @config = config
      @explicit = !sources.nil?
      @selected = sources || Sources::ALL
      @jobs = jobs || DEFAULT_JOBS
      @io = io
      @lock = Mutex.new
      @status = {}
    end

    attr_reader :status

    def run
      static = @selected & Sources::STATIC
      runtime = @selected & Sources::RUNTIME
      threads = static.map { |src| Thread.new { run_static(src) } }
      if @explicit || !runtime.include?("rbs_trace") || !runtime.include?("tracepoint")
        run_runtime(runtime)
      else
        run_runtime(runtime - ["rbs_trace"])
        if (why = tracepoint_insufficient)
          log("rbs_trace: running it (#{why})")
          run_runtime(["rbs_trace"])
        else
          skip("rbs_trace", "tracepoint succeeded; --sources rbs_trace runs it")
        end
      end
      threads.each(&:join)
      @status
    end

    # Why tracepoint's run cannot stand in for rbs_trace's, or nil.
    def tracepoint_insufficient
      return "tracepoint recorded nothing" if Sources.for("tracepoint", @config).read.empty?

      base = baseline
      c = counts("tracepoint")
      if base && base[:total].positive? && c[:total] * 10 < base[:total] * 9
        return "tracepoint's run counted #{c[:total]} #{base[:unit]}, the plain run #{base[:total]}"
      end

      nil
    end

    # A concurrent run to repeat alone: it counted fewer tests or more
    # failures than the best run (the plain run when one is saved), or
    # exited non-zero when that one did not.
    def self.suspect?(c, ok, base, base_ok)
      return false unless base
      return true if c[:total] < base[:total] || c[:failed] > base[:failed]

      !ok && base_ok ? true : false
    end

    private

    def log(msg) = @lock.synchronize { @io.puts(msg) }

    def report(src, state, secs = nil)
      @status[src] = state
      log(secs ? format("  %-10s %-6s %5.1fs", src, state, secs) : format("  %-10s %s", src, state))
    end

    def skip(src, why)
      s = Sources.for(src, @config)
      # A stale earlier run must not reach the draft.
      FileUtils.rm_rf(s.dir)
      FileUtils.rm_f(File.join(@config.out, "#{src}.log"))
      report(src, "skipped (#{why})")
    end

    # [ok, seconds, timed out]
    def timed(src, env = {}, limit: nil)
      t = Time.now
      s = Sources.for(src, @config)
      s.extra_env = env
      s.time_limit = limit
      ok = s.run
      ok = !(ok == false || ok.nil?)
      [ok, Time.now - t, s.timed_out ? true : false]
    end

    # Reused when the inputs are unchanged: the output of a successful run,
    # or the fact that the last run hit the time limit (so a rerun does not
    # wait for it again).
    def run_static(src)
      cache = File.join(@config.out, ".cache", "#{src}.json")
      key = static_key(src)
      saved = (JSON.parse(File.read(cache)) rescue nil) if ENV["GEM_TYPES_FRESH"] != "1" && File.exist?(cache)
      if saved && saved["key"] == key
        return report(src, "cached (inputs unchanged)") if saved["result"] == "ok" && static_output?(src)
        return report(src, "skipped (stopped after #{saved['limit']}s last time with the same inputs; GEM_TYPES_FRESH=1 retries)") if saved["result"] == "timeout"
      end

      FileUtils.rm_f(cache)
      ok, secs, timed_out = timed(src, limit: STATIC_TIMEOUT)
      # Half-written output (or an older run's) must not reach the draft.
      FileUtils.rm_f(File.join(@config.out, "#{src}.rbs")) if timed_out
      if ok || timed_out
        FileUtils.mkdir_p(File.dirname(cache))
        File.write(cache, JSON.generate(key: key, result: ok ? "ok" : "timeout", limit: STATIC_TIMEOUT))
      end
      report(src, ok ? "ok" : (timed_out ? "timeout" : "failed"), secs)
    rescue StandardError => e
      report(src, "failed (#{e.class}: #{e.message})")
    end

    def static_output?(src)
      f = File.join(@config.out, "#{src}.rbs")
      File.exist?(f) && File.size(f).positive?
    end

    # What a static source's output depends on: the source code it reads,
    # the settings, this tool (its code and locked tool versions) and, for
    # prototype, which loads the gem, the gem's environment.
    def static_key(src)
      tool = Fingerprint.files([File.join(ROOT, "Gemfile.lock"), File.join(__dir__, "sources.rb"), LIBEXEC])
      inputs = Fingerprint.files(@config.lib_paths + (src == "yard" || src == "prototype" ? [] : @config.test_paths))
      extra = case src
              when "prototype" then [@config.requires, @config.env.sort, Fingerprint.repo(@config)]
              when "rigor"
                r = Sources.for("rigor", @config)
                [r.ruby, (File.mtime(r.rigor_bin).to_i if r.available?)]
              end
      Fingerprint.of(src, @config.repo, @config.lib_dirs, @config.test_dirs, @config.ns, inputs, tool, extra)
    end

    def run_runtime(list)
      return if list.empty?
      return list.each { |src| run_alone(src) } if @jobs <= 1 || list.size == 1

      results = {}
      list.each_slice(@jobs) do |batch|
        batch.map do |src|
          Thread.new do
            tmp = File.join(@config.out, ".tmp", src)
            FileUtils.rm_rf(tmp)
            FileUtils.mkdir_p(tmp)
            ok, secs, = timed(src, { "TMPDIR" => tmp })
            FileUtils.rm_rf(tmp)
            @lock.synchronize { results[src] = ok }
            report(src, ok ? "ok" : "failed", secs)
          end
        end.each(&:join)
      end
      tmp_root = File.join(@config.out, ".tmp")
      FileUtils.rmdir(tmp_root) if Dir.exist?(tmp_root) && Dir.empty?(tmp_root)
      base = baseline
      base_ok = base ? @plain_ok : nil
      unless base
        # No saved plain run: compare with the best of these runs.
        best = list.max_by { |s| [results[s] ? 1 : 0, counts(s)[:total], -counts(s)[:failed]] }
        base = counts(best)
        base_ok = results[best]
      end
      list.each do |src|
        next unless self.class.suspect?(counts(src), results[src], base, base_ok)

        log("#{src}: the concurrent run looked worse (#{describe(counts(src), results[src])} vs " \
            "#{describe(base, base_ok)}): running it again alone")
        run_alone(src)
      end
    end

    def run_alone(src)
      ok, secs, = timed(src)
      report(src, ok ? "ok" : "failed", secs)
    end

    def describe(c, ok) = "#{c[:total]} #{c[:unit]}, #{c[:failed]} failing#{ok ? '' : ', exit non-zero'}"

    def counts(src)
      f = File.join(@config.out, "#{src}.log")
      File.exist?(f) ? Verify.test_counts(File.read(f, encoding: "UTF-8")) : { total: 0, failed: 0, unit: "tests", outside: 0 }
    end

    # Counts of the saved plain run, when its inputs are unchanged.
    def baseline
      return @baseline if defined?(@baseline)

      hit = PlainRun.new(@config).fetch
      @plain_ok = hit && hit[:ok]
      @baseline = hit && hit[:counts][:total].positive? ? hit[:counts] : nil
    end
  end
end
