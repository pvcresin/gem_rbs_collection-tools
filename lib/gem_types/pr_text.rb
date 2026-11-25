# frozen_string_literal: true

require "json"

module GemTypes
  # Drafts the commit message (= PR description) for a gem's RBS: what is
  # covered, what the source has that the RBS leaves out, and the
  # verification numbers saved by `verify` and `live`. Bullets are a start:
  # describe the API in words before committing.
  module PrText
    module_function

    def build(config, workdir, sig)
      gem = Dir[File.join(workdir, "*.gem")].map { |f| File.basename(f, ".gem").sub(/-[^-]+\z/, "") }.first || "?"
      ver = File.basename(File.directory?(sig) ? sig : File.dirname(sig))
      rbs = RbsReader.read_files(Verify.sig_files(sig))
      defs = DefIndex.new(config.lib_paths)
      out = ["Add RBS for #{gem} #{ver}", "", "Covers the public API of #{gem} #{ver}:", ""]
      rbs.methods.keys.group_by { |k| GemTypes.split_key(k).first }.sort.each do |owner, keys|
        names = keys.map { |k| k.sub(/\A#{Regexp.escape(owner)}/, "") }.sort_by { |n| [n.start_with?(".") ? 0 : 1, n] }
        shown = names.first(8).map { |n| "`#{n}`" }.join(", ")
        out << wrap("- #{owner}: #{shown}#{names.size > 8 ? " and #{names.size - 8} more" : ''}.")
      end
      hidden = defs.hidden.keys.select { |k| config.in_ns?(k) }.sort
      public_missing = (defs.map { |d| d[:key] } | defs.attrs.keys)
                       .reject { |k| rbs.methods.key?(k) || defs.hidden.key?(k) || !config.in_ns?(k) || k.end_with?("#initialize") }
                       .sort
      out << "" << "Left out:" << ""
      out << wrap("- Public but not declared (say why: internal, metaprogramming, ...): #{public_missing.map { |k| "`#{k}`" }.join(', ')}.") unless public_missing.empty?
      out << wrap("- Private or documented as internal: #{hidden.size} methods.") unless hidden.empty?
      out << "- (nothing)" if public_missing.empty? && hidden.empty?
      out << "" << "## Verification" << ""
      out << "- `bin/test` and RuboCop pass."
      v = read_json(File.join(config.out, "verify.json"))
      live = read_json(File.join(config.out, "live.json"))
      out << "- Reviewed the signatures against the gem source; every declared method and class exists in the loaded gem." if v && v["exists"]
      if live
        total = live["checked"].size + live["unchecked"].size
        line = "- Called every declared method with runtime type checking (`rbs/test/setup`)"
        line += live["unchecked"].empty? ? "; every declaration was exercised (#{total}/#{total} fail when their return types are replaced with `bot`)." :
                                           "; #{live['checked'].size}/#{total} declarations were exercised by the runtime checks, the others (#{live['unchecked'].join(', ')}) were checked with assertions."
        out << wrap(line)
      else
        out << "- Called every declared method with runtime type checking (`rbs/test/setup`). (run `gem-types live` to back this line)"
      end
      if v
        c = v["checked"]
        tail = v["errors"].empty? ? "no type errors" : "#{v['errors'].size} distinct type errors (explain: negative tests, test doubles, ...)"
        out << wrap("- Ran the gem's own test suite with runtime type checking: #{c['total']} #{c['unit']}, #{v['checks']} type checks, #{tail}.")
      else
        out << "- (run `gem-types verify` for the test suite numbers)"
      end
      out.join("\n") + "\n"
    end

    def read_json(path) = File.exist?(path) ? JSON.parse(File.read(path)) : nil

    def wrap(text, width = 72)
      lines = []
      line = +""
      text.split(" ").each do |word|
        if !line.empty? && line.size + word.size + 1 > width
          lines << line
          line = +"  "
        end
        line << (line.strip.empty? ? "" : " ") << word
      end
      lines << line
      lines.join("\n")
    end
  end
end
