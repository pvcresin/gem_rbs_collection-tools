# Loaded by rbs_check.sh in checked runs. Skips the tests that measure time
# (a Timeout.timeout or Benchmark around a payload, RSpec metadata such as
# :regexp_timing or :performance): under runtime type checking they only run
# until their timeout, and addressable's ReDoS specs made one checked run
# take hours. GEM_TYPES_KEEP_TIMING=1 keeps them.
module GemTypesSkipTiming
  PATTERN = /\bTimeout\.timeout\b|\bBenchmark\.(?:realtime|measure|bm)\b|\bassert_performance/
  METADATA = /timing|performance|benchmark/
  REASON = "timing test (skipped under runtime type checking by gem-types)"
  @count = 0

  class << self
    attr_accessor :count

    # The source of the block or method defined at file:line, up to its end.
    def body(file, line)
      lines = File.readlines(file, encoding: "UTF-8").map(&:scrub)
      first = lines[line - 1] or return ""
      indent = first[/\A\s*/].size
      out = [first]
      lines[line..(line + 200)].to_a.each do |l|
        out << l
        break if l =~ /\A\s{0,#{indent}}(end|\})\b/
      end
      out.join
    rescue StandardError
      ""
    end

    def timing?(file, line, metadata = {})
      return true if metadata.any? { |k, v| v && k.to_s.match?(METADATA) }
      file && line ? body(file, line).match?(PATTERN) : false
    rescue StandardError
      false
    end
  end

  module RSpecExample
    def run(*args, &blk)
      loc = metadata[:block]&.source_location
      if !metadata[:skip] && GemTypesSkipTiming.timing?(loc&.first, loc&.last, metadata)
        metadata[:skip] = REASON
        GemTypesSkipTiming.count += 1
      end
      super
    end
  end

  module MinitestTest
    def before_setup
      super
      loc = method(name).source_location rescue nil
      return unless loc && GemTypesSkipTiming.timing?(*loc)

      GemTypesSkipTiming.count += 1
      skip REASON
    end
  end

  def self.install
    if !@rspec && defined?(::RSpec::Core::Example)
      ::RSpec::Core::Example.prepend(RSpecExample)
      @rspec = true
    end
    if !@minitest && defined?(::Minitest::Test)
      ::Minitest::Test.prepend(MinitestTest)
      @minitest = true
    end
    @rspec && @minitest
  end
end

unless ENV["GEM_TYPES_KEEP_TIMING"] == "1"
  # RSpec and Minitest load after this file: install when their classes end.
  GemTypesSkipTiming::TRACE = TracePoint.new(:end) do |tp|
    name = (Module.instance_method(:name).bind_call(tp.self) rescue nil)
    if %w[RSpec::Core::Example Minitest::Test].include?(name) && GemTypesSkipTiming.install
      GemTypesSkipTiming::TRACE.disable
    end
  end
  GemTypesSkipTiming::TRACE.enable
  at_exit do
    n = GemTypesSkipTiming.count
    warn "[gem-types] skipped #{n} timing test(s) under runtime type checking (GEM_TYPES_KEEP_TIMING=1 keeps them)" if n.positive?
  end
end
