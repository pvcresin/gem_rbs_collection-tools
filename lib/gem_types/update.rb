# frozen_string_literal: true

require "tmpdir"
require "shellwords"

module GemTypes
  # `gem-types update`: what an existing collection RBS needs for a new
  # version of the gem. The workdir is prepared for the new version.
  module Update
    module_function

    # Prints the report; returns an exit code (0 when nothing needs doing).
    def run(config, workdir, sig, from: nil, libraries: [])
      problems = 0
      defs = DefIndex.new(config.lib_paths)
      rbs = RbsReader.read_files(RbsReader.sig_files(sig), include_private: true)

      if from
        puts "== source changes since #{from} (parameters of public methods)"
        changes = source_changes(workdir, from, defs)
        if changes.nil?
          puts "  (could not fetch #{from})"
        else
          puts "  nothing" if changes.values.all?(&:empty?)
          changes[:removed].each { |k| puts "  removed:  #{k}#{rbs.methods.key?(k) ? '   <- declared in the RBS' : ''}" }
          changes[:added].each { |k| puts "  added:    #{k}" }
          changes[:changed].each { |k, (a, b)| puts "  changed:  #{k}  (#{a}) -> (#{b})#{rbs.methods.key?(k) ? '   <- declared' : ''}" }
        end
        puts
      end

      puts "== declared but gone (exists)"
      problems += 1 unless Verify.exists(config, sig).zero?

      puts "", "== public methods not in the RBS"
      proto = Sources.for("prototype", config)
      proto.run if proto.read.empty?
      seen = proto.read.keys | defs.map { |d| d[:key] } | attr_keys(defs)
      missing = seen.reject { |k| rbs.methods.key?(k) || defs.hidden.key?(k) || !config.in_ns?(k) }
      missing = missing.reject { |k| k.end_with?("#initialize") && rbs.methods.keys.none? { |x| x.start_with?(GemTypes.split_key(k).first) } }
      if missing.empty?
        puts "  nothing"
      else
        merger = draft_merger(config, defs)
        missing.sort.each do |k|
          rbs_sig, src = merger.pick(k)
          puts "  #{k}: #{rbs_sig}#{src ? "   (#{src})" : ''}"
        end
        puts "  (suggestions from the evidence in #{config.out}; run `gem-types collect` for runtime types)"
      end

      puts "", "== steep (code vs signatures)"
      problems += 1 unless Verify.steep(config, sig, libraries).zero?

      if config.test_cmd
        puts "", "== test suite with runtime type checking"
        r = Verify.suite(config, sig)
        puts "  #{r[:checked][:total]} #{r[:checked][:unit]}, #{r[:checks]} type checks, #{r[:errors].size} distinct type errors"
        r[:errors].first(20).each { |e| puts "  #{e[0, 220]}" }
        unless r[:incomplete].to_a.empty?
          puts "  CHECKED RUN INCOMPLETE: #{r[:incomplete].join('; ')} (see #{r[:logs].last})"
          problems += 1
        end
        problems += 1 unless r[:errors].empty?
      end
      problems += 1 unless missing.empty?
      problems.zero? ? 0 : 1
    end

    def draft_merger(config, defs)
      evidence = {}
      Sources::ALL.each do |src|
        h = Sources.for(src, config).read
        evidence[src] = h unless h.empty?
      end
      Merger.new(evidence: evidence, defs: defs)
    end

    # Public methods added, removed or with different parameters between the
    # packaged old version and the new checkout.
    def source_changes(workdir, from, new_defs)
      gem = Dir[File.join(workdir, "*.gem")].map { |f| File.basename(f, ".gem").sub(/-[^-]+\z/, "") }.first or return nil
      Dir.mktmpdir do |tmp|
        ok = system("gem", "fetch", gem, "-v", from, chdir: tmp, out: File::NULL, err: File::NULL)
        pkg = Dir[File.join(tmp, "*.gem")].first
        return nil unless ok && pkg

        FileUtils.mkdir_p(File.join(tmp, "old"))
        system("bash", "-c", "tar -xOf #{pkg.shellescape} data.tar.gz | tar -xz -C old", chdir: tmp) or return nil
        compare_defs(DefIndex.new([File.join(tmp, "old", "lib")]), new_defs)
      end
    end

    # { removed:, added:, changed: } between two DefIndexes' public methods.
    def compare_defs(old_defs, new_defs)
      sig = ->(d) { d[:params].map { |p| "#{p[:kind]} #{p[:name]}" }.join(", ") }
      pub = lambda do |idx|
        h = idx.reject { |d| idx.hidden.key?(d[:key]) }.to_h { |d| [d[:key], sig.(d)] }
        attr_keys(idx).each { |k| h[k] ||= k.end_with?("=") ? "attr writer" : "attr reader" }
        h
      end
      a = pub.(old_defs)
      b = pub.(new_defs)
      { removed: (a.keys - b.keys).sort, added: (b.keys - a.keys).sort,
        changed: (a.keys & b.keys).select { |k| a[k] != b[k] }.sort.map { |k| [k, [a[k], b[k]]] } }
    end

    # The public methods attr_* calls define: `x` for readers, `x=` for
    # writers, both for accessors (a private half left out).
    def attr_keys(defs)
      defs.attrs.flat_map do |k, a|
        keys = []
        keys << k unless a[:kind] == "writer"
        keys << "#{k}=" unless a[:kind] == "reader"
        keys
      end.reject { |k| defs.hidden.key?(k) }
    end
  end
end
