# frozen_string_literal: true

require "json"
require "set"

module GemTypes
  # Checks a commit message (= PR description) before it is committed:
  # the format the collection expects, characters that get mangled on the
  # way to GitHub, method names that are not in the RBS (a misremembered
  # `cloud_run?`, a `prepare` the class does not have), and verification
  # numbers that no longer match the saved verify/live results.
  #
  # Returns [[level, message], ...] with level :error or :warn.
  module MsgCheck
    module_function

    FORBIDDEN = {
      /&(amp|lt|gt|quot|#\d+);/ => "an HTML entity",
      /co-authored-by/i => "a Co-Authored-By trailer",
      /\bclaude\b/i => "the word Claude",
      /generated with/i => "a \"Generated with\" line"
    }.freeze

    def run(text, sig:, gem: nil, workdir: nil)
      out = []
      text = text.dup.force_encoding(Encoding::UTF_8).scrub
      lines = text.lines.map(&:chomp)
      ver = File.basename(File.directory?(sig) ? sig : File.dirname(sig))
      title = lines.first.to_s
      unless title.match?(/\A(Add|Update) RBS for \S+ \d+\.\d+\z/)
        out << [:error, "title should be \"Add RBS for <gem> <version>\" (or Update): #{title.inspect}"]
      end
      out << [:error, "title names version #{title[/ (\d+\.\d+)\z/, 1]}, the RBS is in #{ver}/"] if title[/ (\d+\.\d+)\z/, 1] && title[/ (\d+\.\d+)\z/, 1] != ver
      out << [:error, "title names #{title.split[3]}, not #{gem}"] if gem && title.split[3] && title.split[3] != gem
      out << [:error, "the second line must be blank"] unless lines[1].to_s.empty?
      lines.each_with_index do |l, i|
        out << [:error, "line #{i + 1} has non-ASCII characters: #{l.strip[0, 60]}"] unless l.ascii_only?
        FORBIDDEN.each { |re, what| out << [:error, "line #{i + 1} has #{what}"] if l.match?(re) }
        out << [:warn, "line #{i + 1} is #{l.size} columns (wrap at 72)"] if l.size > 72 && !l.include?("://")
      end
      %w[## Verification ## References].each_slice(2).map { _1.join(" ") }.each do |h|
        out << [:error, "no \"#{h}\" section"] unless lines.include?(h)
      end
      out.concat(name_checks(text, sig))
      out.concat(number_checks(text, workdir)) if workdir
      out.concat(reference_checks(text, workdir)) if workdir
      out
    end

    # Method names the prose claims (`foo?`, `Foo#bar`, list items next to
    # declared names) that the RBS does not declare.
    def name_checks(text, sig)
      rbs = RbsReader.read_files(RbsReader.sig_files(sig), include_private: true)
      names = rbs.methods.keys.map { GemTypes.split_key(_1).last }.to_set
      names << "new" if names.include?("initialize")
      owners = rbs.methods.keys.map { GemTypes.split_key(_1).first } | Array(rbs.classes).map { _1.is_a?(Array) ? _1.first : _1 }.map(&:to_s)
      tops = owners.map { _1.sub(/\A::/, "").split("::").first }.to_set
      prose = text.sub(/^## References.*/m, "").gsub(%r{https?://\S+}, "")
      out = []
      # foo? / foo! / foo= (not in code spans with spaces, not ?: or !=)
      prose.scan(/(?<![\w:.#@$])([a-z_][a-z0-9_]*[?!=])(?=[\s,.;:)\]`]|\z)/).flatten.uniq.each do |n|
        next if names.include?(n) || names.include?(n.chomp("=")) && n.end_with?("=")

        out << [:warn, "#{n} is not declared in the RBS"]
      end
      # Foo::Bar#baz / Foo::Bar.baz under the gem's own namespaces
      prose.scan(/\b((?:[A-Z]\w*::)*[A-Z]\w*)([#.])([a-z_]\w*[?!=]?)/).uniq.each do |owner, sep, m|
        next unless tops.include?(owner.split("::").first)

        key = "#{owner}#{sep}#{m}"
        # Typhoeus.get comes from `extend Request::Actions`: a name declared
        # anywhere is not flagged.
        next if rbs.methods.key?(key) || names.include?(m) || names.include?(m.chomp("="))

        out << [:warn, "#{key} is not declared in the RBS"]
      end
      # Lists: "Foo: a, b, c and d" or "(a, b, c)". When most items are
      # declared method names, the bare identifiers that are not are suspect.
      prose.scan(/\(([^()]+)\)|:\s+([^:\n]+(?:\n  [^:\n-][^:\n]*)*)/).each do |paren, after|
        list = (paren || after).gsub(/\s+/, " ").split(/,\s*|\s+and\s+|\s+or\s+/).map { _1.strip.delete("`").sub(/\.\z/, "") }
        bare = list.select { _1.match?(/\A[a-z_][a-z0-9_]*[?!=]?\z/) }
        known = bare.select { names.include?(_1) }
        next if known.size < 2 || known.size * 2 < bare.size

        (bare - known).each { |n| out << [:warn, "#{n} (listed with declared methods) is not declared in the RBS"] }
      end
      out.uniq
    end

    # "N examples, M type checks" and "a/b declarations" against
    # evidence/verify.json and live.json.
    def number_checks(text, workdir)
      out = []
      v = read(File.join(workdir, "evidence", "verify.json"))
      live = read(File.join(workdir, "evidence", "live.json"))
      flat = text.gsub(/\s+/, " ")
      if v && (m = flat.match(/(\d+) (examples|runs|tests), (\d+) type checks/))
        total = v.dig("checked", "total")
        out << [:error, "the message says #{m[1]} #{m[2]}, verify.json has #{total}"] if total && total != m[1].to_i
        out << [:error, "the message says #{m[3]} type checks, verify.json has #{v['checks']}"] if v["checks"] && v["checks"] != m[3].to_i
      end
      if live && (m = flat.match(%r{(\d+)/(\d+) declarations}))
        total = live["checked"].size + live["unchecked"].size
        got = "#{live['checked'].size}/#{total}"
        out << [:error, "the message says #{m[1]}/#{m[2]} declarations, live.json has #{got} (rerun live after editing the RBS)"] if got != "#{m[1]}/#{m[2]}"
      end
      out
    end

    def reference_checks(text, workdir)
      ref = PrText.references(workdir)
      return [] if ref.empty?

      url = ref.sub(/\A- /, "")
      text.include?(url) ? [] : [[:warn, "References does not link #{url}"]]
    end

    def read(path) = File.exist?(path) ? (JSON.parse(File.read(path)) rescue nil) : nil
  end
end
