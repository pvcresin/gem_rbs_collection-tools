# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/gem_types"

class CollectTest < Minitest::Test
  # Stands in for a source: records runs, writes a log with test counts.
  class FakeSource
    attr_accessor :extra_env, :time_limit
    attr_reader :timed_out

    def initialize(name, config, plan)
      @name = name
      @config = config
      @plan = plan
    end

    def dir = File.join(@config.out, @name)

    def run
      @plan[:runs] << [@name, extra_env]
      FileUtils.mkdir_p(dir)
      File.write(File.join(@config.out, "#{@name}.log"), @plan.dig(:logs, @name) || "10 runs, 10 assertions, 0 failures, 0 errors\n")
      File.write(File.join(@config.out, "#{@name}.rbs"), "class X\nend\n") if GemTypes::Sources::STATIC.include?(@name)
      @timed_out = @plan[:timeout]&.include?(@name)
      !@timed_out
    end

    def read = @plan.dig(:read, @name) || {}
  end

  def setup
    @dir = Dir.mktmpdir
    @repo = File.join(@dir, "repo")
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    FileUtils.mkdir_p(File.join(@repo, "test"))
    File.write(File.join(@repo, "lib", "x.rb"), "class X; end\n")
    File.write(File.join(@repo, "test", "x_test.rb"), "# test\n")
    File.write(File.join(@repo, "Rakefile"), "task :test\n")
    @config = GemTypes::Config.new(repo: @repo, lib_dirs: ["lib"], test_dirs: %w[test spec], ns: ["X"], requires: ["x"],
                                   test_cmd: "rake test", env: {}, out: File.join(@dir, "evidence"))
    @plan = { runs: [], read: {}, logs: {} }
    plan = @plan
    @orig = GemTypes::Sources.method(:for)
    GemTypes::Sources.define_singleton_method(:for) { |name, config| FakeSource.new(name, config, plan) }
  end

  def teardown
    orig = @orig
    GemTypes::Sources.define_singleton_method(:for) { |name, config| orig.call(name, config) }
    FileUtils.rm_rf(@dir)
  end

  def collect(**kw) = GemTypes::Collect.new(@config, io: StringIO.new, **kw).run
  def ran = @plan[:runs].map(&:first)

  def test_rbs_trace_is_skipped_when_tracepoint_recorded_evidence
    @plan[:read]["tracepoint"] = { "X#a" => :e }
    FileUtils.mkdir_p(File.join(@config.out, "rbs_trace"))
    status = collect(sources: nil)
    assert_includes ran, "tracepoint"
    assert_includes ran, "lumitrace"
    refute_includes ran, "rbs_trace"
    assert_match(/skipped/, status["rbs_trace"])
    refute Dir.exist?(File.join(@config.out, "rbs_trace")), "a stale rbs_trace output must not reach the draft"
  end

  def test_rbs_trace_runs_when_tracepoint_recorded_nothing
    collect
    assert_includes ran, "rbs_trace"
  end

  def test_rbs_trace_runs_when_tracepoint_ran_far_fewer_tests_than_the_plain_run
    @plan[:read]["tracepoint"] = { "X#a" => :e }
    log = File.join(@dir, "plain.log")
    File.write(log, "100 runs, 100 assertions, 0 failures, 0 errors\n")
    GemTypes::PlainRun.new(@config).store(log, true)
    collect
    assert_includes ran, "rbs_trace"
  end

  def test_named_sources_run_as_given
    @plan[:read]["tracepoint"] = { "X#a" => :e }
    collect(sources: %w[tracepoint rbs_trace])
    assert_equal %w[rbs_trace tracepoint], ran.sort
  end

  def test_runtime_sources_run_together_with_their_own_tmpdir
    @plan[:read]["tracepoint"] = { "X#a" => :e }
    collect(sources: %w[tracepoint lumitrace])
    envs = @plan[:runs].map(&:last)
    assert(envs.all? { |e| e["TMPDIR"] })
    assert_equal 2, envs.map { |e| e["TMPDIR"] }.uniq.size
  end

  def test_jobs_1_runs_one_at_a_time_without_tmpdir
    collect(sources: %w[tracepoint lumitrace], jobs: 1)
    assert(@plan[:runs].all? { |_, env| env.empty? })
  end

  def test_a_worse_concurrent_run_is_repeated_alone
    @plan[:logs]["lumitrace"] = "3 runs, 3 assertions, 0 failures, 0 errors\n"
    collect(sources: %w[tracepoint lumitrace])
    assert_equal %w[lumitrace lumitrace tracepoint], ran.sort
    assert_empty @plan[:runs].last.last, "the repeat runs alone, without the concurrent TMPDIR"
  end

  def test_timeout_failures_are_not_repeated_alone
    @plan[:logs]["lumitrace"] = <<~LOG
      Failures:

        1) T matches in linear time
           Failure/Error:
             expected no Exception, got #<Timeout::Error: execution expired> with backtrace:

      Finished in 1 second
      10 examples, 1 failure
    LOG
    @plan[:logs]["tracepoint"] = "10 examples, 0 failures\n"
    collect(sources: %w[tracepoint lumitrace])
    assert_equal %w[lumitrace tracepoint], ran.sort
  end

  def test_suspect
    base = { total: 10, failed: 1 }
    refute GemTypes::Collect.suspect?({ total: 10, failed: 1 }, true, base, true)
    assert GemTypes::Collect.suspect?({ total: 9, failed: 1 }, true, base, true)
    assert GemTypes::Collect.suspect?({ total: 10, failed: 2 }, true, base, true)
    assert GemTypes::Collect.suspect?({ total: 10, failed: 1 }, false, base, true)
    refute GemTypes::Collect.suspect?({ total: 10, failed: 1 }, false, base, false)
    refute GemTypes::Collect.suspect?({ total: 0, failed: 0 }, false, nil, true)
  end

  def test_static_sources_are_reused_while_inputs_are_unchanged
    collect(sources: %w[tyda])
    collect(sources: %w[tyda])
    assert_equal ["tyda"], ran
    File.write(File.join(@repo, "lib", "x.rb"), "class X; def a = 1; end\n")
    collect(sources: %w[tyda])
    assert_equal %w[tyda tyda], ran
    ENV["GEM_TYPES_FRESH"] = "1"
    collect(sources: %w[tyda])
    assert_equal %w[tyda tyda tyda], ran
  ensure
    ENV.delete("GEM_TYPES_FRESH")
  end

  def test_a_static_source_that_timed_out_is_not_waited_for_again
    @plan[:timeout] = ["typeprof"]
    collect(sources: %w[typeprof])
    refute File.exist?(File.join(@config.out, "typeprof.rbs")), "half-written output is removed"
    status = collect(sources: %w[typeprof])
    assert_equal ["typeprof"], ran
    assert_match(/stopped after/, status["typeprof"])
  end

  def test_plain_run_is_reused_until_an_input_changes
    log = File.join(@dir, "plain.log")
    File.write(log, "5 runs, 5 assertions, 1 failures, 0 errors\n")
    pr = GemTypes::PlainRun.new(@config)
    pr.store(log, false)
    hit = pr.fetch
    assert_equal false, hit[:ok]
    assert_equal 5, hit[:counts][:total]

    # What tests write (tmp/, coverage/, logs, RSpec status) does not count.
    FileUtils.mkdir_p(File.join(@repo, "test", "tmp"))
    File.write(File.join(@repo, "test", "tmp", "scratch"), "x")
    File.write(File.join(@repo, ".rspec_status"), "x")
    refute_nil pr.fetch

    File.write(File.join(@repo, "test", "x_test.rb"), "# changed\n")
    assert_nil pr.fetch
  end

  def test_plain_run_is_not_reused_for_another_command_or_an_edited_log
    log = File.join(@dir, "plain.log")
    File.write(log, "5 runs, 5 assertions, 0 failures, 0 errors\n")
    GemTypes::PlainRun.new(@config).store(log, true)
    other = @config.dup
    other.test_cmd = "rake spec"
    assert_nil GemTypes::PlainRun.new(other).fetch
    File.write(log, "6 runs, 6 assertions, 0 failures, 0 errors\n")
    assert_nil GemTypes::PlainRun.new(@config).fetch
  end

  def test_time_limit_stops_a_command
    src = GemTypes::Sources::Base.new(@config)
    src.time_limit = 1
    t = Time.now
    refute src.sh({}, "sleep 20", chdir: @dir, log: File.join(@dir, "t.log"))
    assert src.timed_out
    assert_operator Time.now - t, :<, 15
    src.time_limit = 5
    assert src.sh({}, "echo 'a b' > out", chdir: @dir, log: File.join(@dir, "t.log"))
    refute src.timed_out
    assert_equal "a b\n", File.read(File.join(@dir, "out"))
  end

  def test_run_records_its_plain_run_for_verify
    w = @dir
    log = File.join(w, "tests.log")
    File.write(log, "7 runs, 7 assertions, 0 failures, 0 errors\n")
    env = { "BUNDLE_GEMFILE" => File.join(w, "env", "Gemfile"), "GEM_HOME" => File.join(w, "gemhome") }
    GemTypes::Batch.new([], base: w).send(:save_plain_run, w, @repo, env, "rake test", log, true)
    later = GemTypes::Config.new(repo: @repo, lib_dirs: ["lib"], test_dirs: %w[test spec], ns: ["X"], requires: ["x"],
                                 test_cmd: "rake test", env: env, out: File.join(w, "evidence"))
    assert_equal 7, GemTypes::PlainRun.new(later).fetch[:counts][:total]
  end
end
