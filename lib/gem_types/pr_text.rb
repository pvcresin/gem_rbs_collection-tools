# frozen_string_literal: true

require "json"
require "yaml"
require "shellwords"

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
      rbs = RbsReader.read_files(RbsReader.sig_files(sig))
      defs = DefIndex.new(config.lib_paths)
      out = ["Add RBS for #{gem} #{ver}", "", "Covers the public API of #{gem} #{ver}:", ""]
      rbs.methods.keys.group_by { |k| GemTypes.split_key(k).first }.sort.each do |owner, keys|
        names = keys.map { |k| k.sub(/\A#{Regexp.escape(owner)}/, "") }.sort_by { |n| [n.start_with?(".") ? 0 : 1, n] }
        shown = names.first(8).map { |n| "`#{n}`" }.join(", ")
        out << wrap("- #{owner}: #{shown}#{names.size > 8 ? " and #{names.size - 8} more" : ''}.")
      end
      # The private instance copies made by module_function are not API left out.
      hidden = defs.hidden.reject { |_, why| why == "module_function" }.keys.select { |k| config.in_ns?(k) }.sort
      public_missing = (defs.map { |d| d[:key] } | Update.attr_keys(defs))
                       .reject { |k| rbs.methods.key?(k) || defs.hidden.key?(k) || !config.in_ns?(k) || k.end_with?("#initialize") }
                       .reject { |k| HOOKS.include?(GemTypes.split_key(k).last) }
                       .sort
      out << "" << "Left out:" << ""
      out << wrap("- Public but not declared (say why: internal, metaprogramming, ...): #{summarize(public_missing)}.") unless public_missing.empty?
      out << wrap("- Private or documented as internal: #{hidden.size} methods.") unless hidden.empty?
      out << "- (nothing)" if public_missing.empty? && hidden.empty?
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      manifest = File.join(sigdir, "manifest.yaml")
      if File.exist?(manifest)
        libs = Array((YAML.safe_load_file(manifest) || {})["dependencies"]).filter_map { _1["name"] if _1.is_a?(Hash) }
        text = RbsReader.sig_files(sig).map { |f| File.read(f, encoding: "UTF-8") }.join("\n")
        uses = libs.map do |l|
          consts = Lint::STDLIB.select { |c, lib| lib == l && text.match?(/\b#{Regexp.escape(c)}\b/) }.keys
          consts.empty? ? "`#{l}`" : "`#{l}` (#{consts.join(', ')})"
        end
        out << "" << wrap("manifest.yaml lists the stdlib libraries the signatures refer to: #{uses.join(', ')}.")
      end
      pkg = File.join(workdir, "pkg")
      if File.directory?(pkg)
        out << "" << (Dir[File.join(pkg, "sig", "**", "*.rbs")].empty? ? "The gem does not ship RBS (no sig/ in the #{ver} package)." :
                                                                   "NOTE: the package has sig/: explain why these are needed.")
      end
      out << "" << "## Verification" << ""
      out << "- `bin/test`, RuboCop, `rbs parse` and strict_rubocop_config.rb pass."
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
        if v.key?("suite_complete") && !v["suite_complete"]
          out << wrap("- CHECKED RUN INCOMPLETE (#{Array(v['incomplete']).join('; ')}): fix the run and rerun `gem-types verify` before claiming a test suite result.")
        else
          tail = v["errors"].empty? ? "no type errors" : "#{v['errors'].size} distinct type errors (explain: negative tests, test doubles, ...)"
          out << wrap("- Ran the gem's own test suite with runtime type checking: #{c['total']} #{c['unit']}, #{v['checks']} type checks, #{tail}.")
        end
      else
        out << "- (run `gem-types verify` for the test suite numbers)"
      end
      refs = references(workdir)
      out << "" << "## References" << "" << refs unless refs.empty?
      out.join("\n") + "\n"
    end

    # The source repository at the release tag (or commit) the RBS was
    # checked against.
    def references(workdir)
      repo = File.join(workdir, "repo")
      return "" unless File.directory?(File.join(repo, ".git"))
    
      url = `git -C #{repo.shellescape} remote get-url origin 2>/dev/null`.strip.sub(/\.git\z/, "")
      return "" unless url.start_with?("https://")
    
      pkg = Dir[File.join(workdir, "*.gem")].map { File.basename(_1, ".gem") }.first.to_s
      gem, ver = pkg.match(/\A(.+)-([^-]+)\z/)&.captures
      # The release tag of this gem: a monorepo tags each gem
      # (google-cloud-core/v1.9.1), and a checkout may sit on another gem's
      # tag (describe gave google-cloud-data_catalog-lineage/v1.3.1).
      cands = ver ? ["v#{ver}", ver, "#{gem}/v#{ver}", "#{gem}-v#{ver}", "#{gem}-#{ver}"] : []
      here = `git -C #{repo.shellescape} tag --points-at HEAD 2>/dev/null`.split
      tag = cands.find { here.include?(_1) }
      tag ||= cands.find { !`git -C #{repo.shellescape} ls-remote --tags origin refs/tags/#{_1.shellescape} 2>/dev/null`.strip.empty? } unless cands.empty?
      tag ||= `git -C #{repo.shellescape} describe --tags --exact-match 2>/dev/null`.strip
      ref = tag.empty? ? `git -C #{repo.shellescape} rev-parse HEAD 2>/dev/null`.strip : tag
      sub = File.exist?(File.join(workdir, "repo_dir")) ? File.read(File.join(workdir, "repo_dir")).strip : ""
      sub = sub.delete_prefix(File.expand_path(repo)).delete_prefix("/")
      "- #{url}/tree/#{ref}#{sub.empty? ? "" : "/#{sub}"}"
    end

    # Ruby's callbacks, not API users call.
    HOOKS = %w[included extended inherited prepended method_added].freeze

    # Lists methods one by one, except classes with more than 3 of them, and
    # whole namespaces when they still add up to many lines.
    def summarize(keys)
      by_owner = keys.group_by { |k| GemTypes.split_key(k).first }
      items = by_owner.flat_map do |owner, ks|
        ks.size > 3 ? [[owner, "`#{owner}` (#{ks.size} methods)", ks.size]] : ks.map { |k| [owner, "`#{k}`", 1] }
      end
      if items.size > 12
        items = items.group_by { |owner, _, _| owner.split("::").first(2).join("::") }.map do |ns, list|
          n = list.sum { _3 }
          list.size > 2 ? [ns, "`#{ns}::*` (#{n} methods)", n] : list
        end
        items = items.flat_map { |x| x.first.is_a?(Array) ? x : [x] }
      end
      items.map { _2 }.join(", ")
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
