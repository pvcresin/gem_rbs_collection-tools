# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"
require "rbs"

module GemTypes
  # Widens declarations that reject values the gem really passes or
  # returns: runs test commands under RBS runtime type checking (log mode),
  # reads PREFIX.errors.jsonl (libexec/log_errors.rb) and, for each type
  # error on a call that ended normally, unions the observed class into the
  # exact slot by replacing the slot's text at its location in the
  # signature file (formatting and comments elsewhere stay as they are).
  #
  # Conservative by design: values of anonymous classes, test doubles,
  # classes the tests define and classes without RBS are skipped; calls
  # that raised (negative tests) are ignored; overload resolution failures,
  # arity and block errors are only reported.
  module Repair
    module_function

    TEST_PATH = %r{(\A|/)(test|spec|features)/}
    # Instances of these are placeholders in tests (`Object.new`), not
    # types the gem works with.
    PLACEHOLDER = %w[Object BasicObject].freeze
    # More distinct element (key, value) types than this make it untyped.
    MAX_ELEMENT_TYPES = 3

    # One planned widening of one slot.
    # edit: [start, end] character offsets of the slot in file.
    Change = Struct.new(:file, :line, :key, :slot, :old, :new, :count, :frame, :observed, :round, :edit, keyword_init: true)

    # --- type mapping ---------------------------------------------------

    # The RBS type for a value description from errors.jsonl, as
    # [type, nil], or [nil, reason] when the value must not widen anything.
    # test_file: a predicate telling whether a source file belongs to the
    # tests.
    def rbs_type(desc, test_file: ->(path) { path.to_s.match?(TEST_PATH) }, depth: 0)
      desc = desc.transform_keys(&:to_s)
      if desc["mod"]
        mod = desc["mod"].transform_keys(&:to_s)
        type, why = named(mod, test_file)
        return [nil, why] unless type

        return ["singleton(#{mod['c']})", nil]
      end
      case desc["c"]
      when "TrueClass", "FalseClass" then return ["bool", nil]
      when "NilClass" then return ["nil", nil]
      end
      type, why = named(desc, test_file)
      return [nil, why] unless type

      case desc["c"]
      when "Array", "Set"
        return ["#{desc['c']}[untyped]", nil] if depth.positive? || desc["more"] || desc["e"].to_a.empty?

        elem, why = union_of(desc["e"], test_file)
        elem ? ["#{desc['c']}[#{elem}]", nil] : [nil, why]
      when "Hash"
        return ["Hash[untyped, untyped]", nil] if depth.positive? || desc["more"] || desc["k"].to_a.empty?

        k, why = union_of(desc["k"], test_file)
        return [nil, why] unless k

        v, why = union_of(desc["v"], test_file)
        v ? ["Hash[#{k}, #{v}]", nil] : [nil, why]
      else
        tp = desc["tp"].to_i
        [tp.positive? ? "#{desc['c']}[#{(['untyped'] * tp).join(', ')}]" : desc["c"], nil]
      end
    end

    def union_of(descs, test_file)
      types = []
      descs.each do |d|
        t, why = rbs_type(d, test_file: test_file, depth: 1)
        return [nil, "element: #{why}"] unless t

        types << t
      end
      types.uniq!
      # A mixed bag (option hashes, heterogeneous arrays) reads better and
      # is no less true as untyped.
      return ["untyped", nil] if types.size > MAX_ELEMENT_TYPES

      nilable = types.delete("nil")
      body = types.join(" | ")
      return ["nil", nil] if body.empty?

      [nilable ? (types.size == 1 ? "#{body}?" : "(#{body})?") : body, nil]
    end

    # A named class that may appear in an RBS: [name, nil] or [nil, reason].
    def named(desc, test_file)
      name = desc["c"]
      return [nil, "anonymous class#{desc['sup'] ? " (a subclass of #{desc['sup']})" : ''}"] if desc["anon"] || name.nil? || name.empty?
      return [nil, "test double (#{name})"] if name.match?(GemTypes::TEST_DOUBLE)
      return [nil, "a plain #{name} (a placeholder?)"] if PLACEHOLDER.include?(name)
      return [nil, "#{name} is defined by the tests#{sup_hint(desc)}"] if desc["src"] && test_file.(desc["src"])
      return [nil, "#{name} has no RBS declaration#{sup_hint(desc)}"] unless desc["known"]

      [name, nil]
    end

    def sup_hint(desc) = desc["sup"] ? " (nearest declared ancestor: #{desc['sup']}; widen by hand if that is right)" : ""

    # --- widening -------------------------------------------------------

    # old_text widened by the given RBS types (strings), or nil when it
    # already covers them as far as the text shows. wrap: parenthesize a
    # top-level union (return types, where `|` would start another
    # overload; `*rest`/`**rest`, for readability).
    def widen(old_text, additions, wrap: false)
      parsed = RBS::Parser.parse_type(old_text)
      return nil if parsed.nil? || top?(parsed)

      nilable = false
      inner = parsed
      if inner.is_a?(RBS::Types::Optional)
        nilable = true
        inner = inner.type
      end
      members = if inner.is_a?(RBS::Types::Union)
                  inner.types.map { |t| [t, src(t, old_text)] }
                else
                  [[inner, src(inner, old_text)]]
                end
      changed = false
      flat_members(additions).each do |at, add|
        if at.is_a?(RBS::Types::Bases::Nil)
          changed ||= !nilable
          nilable = true
          next
        end
        next if members.any? { |t, s| s == add || t.to_s == at.to_s }

        same = members.index { |t, _| generic_match?(t, at) }
        if same
          t, s = members[same]
          merged = merge_args(t, s, at)
          if merged && merged != s
            members[same] = [RBS::Parser.parse_type(merged), merged]
            changed = true
          end
          next
        end
        members << [at, add]
        changed = true
      end
      return nil unless changed

      texts = members.map { |t, s| needs_parens?(t) ? "(#{s})" : s }
      body = texts.join(" | ")
      out = if texts.empty? then "nil"
            elsif nilable && texts.size == 1 then "#{body}?"
            elsif nilable then "(#{body})?"
            else body
            end
      wrap && texts.size > 1 && !nilable ? "(#{out})" : out
    end

    # The additions as [type, text] members: unions are split, `T?` gives
    # T and nil.
    def flat_members(additions)
      additions.flat_map do |add|
        t = RBS::Parser.parse_type(add)
        case t
        when RBS::Types::Union then flat_members(t.types.map { src(_1, add) })
        when RBS::Types::Optional then flat_members([src(t.type, add), "nil"])
        else [[t, add]]
        end
      end
    end

    def top?(type) = type.is_a?(RBS::Types::Bases::Any) || type.is_a?(RBS::Types::Bases::Top)

    # The source text of a type parsed from text (its own spelling, not
    # the normalized to_s). A parenthesized type's location leaves the
    # parentheses out; needs_parens? puts them back where they matter.
    def src(type, text)
      loc = type.location
      loc ? text[loc.start_pos...loc.end_pos] : type.to_s
    end

    def needs_parens?(type)
      type.is_a?(RBS::Types::Intersection) || type.is_a?(RBS::Types::Proc) || type.is_a?(RBS::Types::Union)
    end

    def generic_match?(member, add)
      member.is_a?(RBS::Types::ClassInstance) && add.is_a?(RBS::Types::ClassInstance) &&
        member.name.to_s.delete_prefix("::") == add.name.to_s.delete_prefix("::") &&
        !member.args.empty? && member.args.size == add.args.size
    end

    # `Array[String]` widened by `Array[Integer]` -> `Array[String | Integer]`,
    # keeping the member's own text for the name and untouched arguments.
    def merge_args(_member, text, add)
      member = RBS::Parser.parse_type(text) # locations relative to text
      parts = member.args.each_with_index.map do |arg, i|
        atext = src(arg, text)
        new_arg = add.args[i]
        if new_arg.is_a?(RBS::Types::Bases::Any)
          top?(arg) ? atext : "untyped"
        else
          widen(atext, [new_arg.to_s]) || atext
        end
      end
      name = text[/\A[^\[]*/]
      "#{name}[#{parts.join(', ')}]"
    end

    # Literal values (`:c` for a slot typed `:a | :b`) widen the literal
    # union rather than adding the whole class.
    def literal_addition(declared_text, desc)
      lit = desc["lit"] || desc[:lit] or return nil
      parsed = RBS::Parser.parse_type(declared_text)
      parsed = parsed.type if parsed.is_a?(RBS::Types::Optional)
      members = parsed.is_a?(RBS::Types::Union) ? parsed.types : [parsed]
      return nil unless members.any? { _1.is_a?(RBS::Types::Literal) }

      RBS::Parser.parse_type(lit).is_a?(RBS::Types::Literal) ? lit : nil
    rescue RBS::ParsingError
      nil
    end

    # Class names in an RBS type string made absolute: Array[Foo::Bar] ->
    # ::Array[::Foo::Bar].
    def absolutize(type) = type.gsub(/(?<![\w:])([A-Z]\w*)/, '::\1')

    # Replaces [start, end) of text (character offsets) for each edit,
    # from the last to the first so earlier offsets stay valid.
    def splice(text, edits)
      out = text.dup
      edits.sort_by { -_1[0] }.each { |s, e, new| out[s...e] = new }
      out
    end

    # --- running ---------------------------------------------------------

    def slot_label(slot)
      slot = slot.transform_keys(&:to_s)
      base = case slot["pos"]
             when "return" then "return"
             when "key" then "keyword #{slot['name']}"
             when "rest" then "*rest#{slot['name'] ? " #{slot['name']}" : ''}"
             when "keyrest" then "**rest#{slot['name'] ? " #{slot['name']}" : ''}"
             else "#{slot['pos']} param #{slot['index']}#{slot['name'] ? " (#{slot['name']})" : ''}"
             end
      slot["block"] ? "block #{base}" : base
    end

    # Merges the records of several processes (same record, summed counts).
    def read_records(path)
      return [] unless File.exist?(path)

      merged = {}
      File.foreach(path, encoding: "UTF-8") do |l|
        next if l.strip.empty?

        r = JSON.parse(l)
        id = JSON.generate(r.except("count", "frame"))
        if (m = merged[id])
          m["count"] += r["count"].to_i
          m["frame"] ||= r["frame"]
        else
          merged[id] = r.merge("count" => r["count"].to_i)
        end
      end
      merged.values
    end

    # Plans the widenings for one run's records. files: the signature
    # files repair may edit. Returns { changes: [Change], skipped: [...],
    # reported: [...], deferred: n }; changes carry :edit [start, end, new].
    def plan(records, files:, test_file:, round: 1)
      files = files.to_h { |f| [File.realpath(f), f] }
      skipped = []
      reported = []
      groups = Hash.new { |h, k| h[k] = [] }
      records.each do |r|
        if r["slot"].nil?
          reported << { key: r["key"], kind: r["kind"], method_types: r["method_types"] || [r["method_type"]].compact,
                        args: (r["args"] || []).map { |d| d["c"] || d["mod"]&.fetch("c", nil) || "(anon)" },
                        outcome: r["outcome"], count: r["count"], frame: r["frame"] }
          next
        end
        loc = r["loc"]
        file = loc && (File.realpath(loc["file"]) rescue nil)
        unless file && files[file]
          skipped << { key: r["key"], slot: slot_label(r["slot"]), declared: r["declared"], count: r["count"],
                       reason: loc ? "declared outside the signatures being repaired (#{loc['file']})" : "no source location" }
          next
        end
        groups[[file, loc["start"], loc["end"]]] << r
      end

      changes = []
      groups.each do |(file, s, e), recs|
        text = File.read(files[file], encoding: "UTF-8")
        old = text[s...e]
        first = recs.first
        unless old && same_type?(old, first["declared"])
          skipped << { key: first["key"], slot: slot_label(first["slot"]), declared: first["declared"], count: recs.sum { _1["count"] },
                       reason: "the signature file changed since the run (#{old.inspect} at #{s})" }
          next
        end
        normal, raised = recs.partition { _1["outcome"] != "raise" }
        # What a test-defined receiver returns or yields may come from the
        # test's own overrides or stubs (a test case including a DSL module
        # and replacing what it delegates to): leave those alone.
        outward = first["slot"]["pos"] == "return" ? !first["slot"]["block"] : first["slot"]["block"]
        if outward
          stubbed, normal = normal.partition do |r|
            recv = r["recv"] || {}
            recv["src"] && test_file.(recv["src"])
          end
          stubbed.each do |r|
            skipped << { key: r["key"], slot: slot_label(r["slot"]), declared: old, count: r["count"], frame: r["frame"],
                         reason: "the receiver's class #{r['recv']['c']} is defined by the tests (may be stubbed)",
                         value: r["value"]["c"] || "(anon)" }
          end
        end
        adds = {}
        normal.each do |r|
          type = literal_addition(old, r["value"])
          type, why = rbs_type(r["value"], test_file: test_file) unless type
          if type
            (adds[type] ||= { count: 0, frame: nil, keys: [] })[:count] += r["count"]
            adds[type][:frame] ||= r["frame"]
            adds[type][:keys] |= [r["key"]]
          else
            skipped << { key: r["key"], slot: slot_label(r["slot"]), declared: old, count: r["count"], reason: why, frame: r["frame"] }
          end
        end
        raised.each do |r|
          skipped << { key: r["key"], slot: slot_label(r["slot"]), declared: old, count: r["count"],
                       reason: "only in calls that raised #{r['exc']} (negative test?)", frame: r["frame"],
                       value: r["value"]["c"] || "(anon)" }
        end
        next if adds.empty?

        # Spell the added names like the slot does (`::String` style).
        adds = adds.transform_keys { |t| absolutize(t) } if old.match?(/(?<![\w:])::[A-Z]/)
        new = widen(old, adds.keys, wrap: %w[return rest keyrest].include?(first["slot"]["pos"]))
        unless new
          skipped << { key: first["key"], slot: slot_label(first["slot"]), declared: old, count: adds.values.sum { _1[:count] },
                       reason: "observed #{adds.keys.join(', ')} already covered as far as the text shows (sampled elements?)" }
          next
        end
        keys = adds.values.flat_map { _1[:keys] }.uniq
        changes << Change.new(file: files[file], line: text[0...s].count("\n") + 1, key: keys.join(", "),
                              slot: slot_label(first["slot"]), old: old, new: new,
                              count: adds.values.sum { _1[:count] }, frame: adds.values.filter_map { _1[:frame] }.first,
                              observed: adds.keys, round: round, edit: [s, e])
      end
      { changes: changes, skipped: merge_counts(skipped, %i[key slot declared reason value]),
        reported: merge_counts(reported, %i[key kind method_types args outcome]) }
    end

    # Entries that agree on fields, with their counts summed.
    def merge_counts(entries, fields)
      entries.group_by { |e| e.values_at(*fields) }.map do |_, es|
        es.first.merge(count: es.sum { _1[:count].to_i })
      end
    end

    # Whether the slot text still spells the type the run reported.
    # rbs/test prints names resolved to absolute ones (`Base` in `class
    # Thor` is `::Thor::Base`), so namespaces are left out of the
    # comparison: the location already pins the slot.
    def same_type?(text, declared)
      norm = ->(t) { t.gsub(/(?:::)?(?:[A-Z]\w*::)+(?=[A-Za-z_])/, "").gsub(/(\A|[^\w])::/, '\1') }
      norm.(RBS::Parser.parse_type(text).to_s) == norm.(declared)
    rescue RBS::ParsingError
      false
    end

    # Applies the changes file by file. A change whose slot overlaps one
    # already applied this round waits for the next round; a file whose
    # result does not parse is left as it was. Returns [applied, deferred,
    # failed].
    def apply(changes)
      applied = []
      deferred = []
      failed = []
      changes.group_by(&:file).each do |file, cs|
        taken = []
        mine = cs.sort_by { _1.edit[0] }.select do |c|
          if taken.any? { |s, e| c.edit[0] < e && s < c.edit[1] }
            deferred << c
            false
          else
            taken << c.edit
            true
          end
        end
        text = File.read(file, encoding: "UTF-8")
        out = splice(text, mine.map { |c| [*c.edit, c.new] })
        begin
          RBS::Parser.parse_signature(RBS::Buffer.new(name: file, content: out))
        rescue RBS::BaseError => e
          failed.concat(mine.map { |c| [c, e.message.lines.first.to_s.strip] })
          next
        end
        File.write(file, out)
        applied.concat(mine)
      end
      [applied, deferred, failed]
    end

    # Whether a file (a class's source location) belongs to the tests: a
    # path under one of the test dirs of the repo, or with a test/, spec/
    # or features/ directory relative to the repo.
    def test_file_predicate(config)
      repo = File.expand_path(config.repo)
      lambda do |path|
        full = File.expand_path(path.to_s, repo)
        next false unless full.start_with?("#{repo}/")

        rel = full.delete_prefix("#{repo}/")
        config.test_dirs.any? { |d| rel.start_with?("#{d.chomp('/')}/") } || rel.match?(TEST_PATH)
      end
    end

    # One checked run of cmd; returns [records, ok, log].
    def checked_run(config, sig, cmd, prefix)
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      rbs = RbsReader.read_files(Verify.sig_files(sigdir), include_private: true)
      # Classes outside the namespace that the RBS reopens are checked too,
      # but only for the methods it declares (as `live` does).
      reopened = rbs.classes.keys.reject { |c| config.in_ns?("#{c}#x") }
      targets = (config.ns.flat_map { |n| [n, "#{n}::*"] } + reopened).join(",")
      only = rbs.methods.keys.select { |k| reopened.include?(GemTypes.split_key(k).first) }
      env = only.empty? ? config.env : config.env.merge("RBS_TEST_ONLY_METHODS" => only.join(","))
      double = cmd.include?("rspec") ? "rspec" : "minitest"
      FileUtils.rm_f(["#{prefix}.errors.jsonl", "#{prefix}.errors.tsv", "#{prefix}.checked.tsv"])
      check = File.join(LIBEXEC, "rbs_check.sh")
      log = "#{prefix}.log"
      ok = Sources::Base.new(config).sh(env, "#{check.shellescape} -s #{sigdir.shellescape}#{Verify.dep_sig_args(config, sig)} " \
                                             "-t #{targets.shellescape} -d #{double} -o #{prefix.shellescape} -- #{GemTypes.timed(cmd)}",
                                        chdir: config.repo, log: log)
      checks = File.exist?("#{prefix}.checked.tsv") ? File.readlines("#{prefix}.checked.tsv").sum(&:to_i) : 0
      [read_records("#{prefix}.errors.jsonl"), ok, log, checks]
    end

    # The repair loop. cmds: the commands to run (the test suite, a
    # call-every-method script). Returns the report hash (also written to
    # <out>/repair.json).
    def run(config, sig, cmds, rounds: 3, dry_run: false, io: $stdout)
      files = Verify.sig_files(sig)
      Verify.parse_sigs(sig)
      dir = File.join(config.out, "repair")
      FileUtils.mkdir_p(dir)
      test_file = test_file_predicate(config)
      report = { sig: sig, cmds: cmds, dry_run: dry_run, rounds: [], changes: [], skipped: [], reported: [], failed: [] }
      (1..(dry_run ? 1 : rounds)).each do |round|
        records = []
        runs = cmds.each_with_index.map do |cmd, i|
          recs, ok, log, checks = checked_run(config, sig, cmd, File.join(dir, "round#{round}-#{i}"))
          records.concat(recs)
          { cmd: cmd, ok: ok, log: log, checks: checks, errors: recs.size }
        end
        runs.each do |r|
          io.puts "round #{round}: #{r[:cmd]}: #{r[:checks]} type checks, #{r[:errors]} distinct errors#{r[:ok] ? '' : " (exited non-zero, see #{r[:log]})"}"
          io.puts "  WARNING: no type checks recorded: the run did not exercise the signatures" if r[:checks].zero?
        end
        p = plan(records, files: files, test_file: test_file, round: round)
        report[:skipped] = p[:skipped]
        report[:reported] = p[:reported]
        if dry_run
          report[:changes] = p[:changes]
          report[:rounds] << { round: round, runs: runs, planned: p[:changes].size }
          break
        end
        applied, deferred, failed = apply(p[:changes])
        report[:changes].concat(applied)
        report[:failed].concat(failed.map { |c, msg| change_h(c).merge(error: msg) })
        report[:rounds] << { round: round, runs: runs, applied: applied.size, deferred: deferred.size, failed: failed.size }
        break if applied.empty?
      end
      write_report(config, report)
      print_summary(report, io)
      report
    end

    def change_h(c) = c.to_h.except(:edit).merge(file: c.file)

    def write_report(config, report)
      report[:json] = File.join(config.out, "repair.json")
      out = report.merge(changes: report[:changes].map { change_h(_1) })
      File.write(report[:json], JSON.pretty_generate(out))
    end

    def print_summary(report, io)
      verb = report[:dry_run] ? "would widen" : "widened"
      io.puts "", "== #{verb} #{report[:changes].size} slot(s)"
      report[:changes].each do |c|
        io.puts "  #{File.basename(c.file)}:#{c.line} #{c.key} #{c.slot}: #{c.old} -> #{c.new}"
        io.puts "    #{c.count}x, round #{c.round}#{c.frame ? ", e.g. #{c.frame}" : ''}"
      end
      unless report[:failed].empty?
        io.puts "", "== not applied: the result did not parse (#{report[:failed].size})"
        report[:failed].each { |c| io.puts "  #{c[:key]} #{c[:slot]}: #{c[:old]} -> #{c[:new]}: #{c[:error]}" }
      end
      unless report[:skipped].empty?
        io.puts "", "== type errors left alone (#{report[:skipped].size}; check each by hand)"
        report[:skipped].each { |s| io.puts "  #{s[:key]} #{s[:slot]} (#{s[:declared]}): #{s[:reason]}#{s[:count] ? " [#{s[:count]}x]" : ''}" }
      end
      unless report[:reported].empty?
        io.puts "", "== not widened automatically (overloads, arity, blocks: decide by hand) (#{report[:reported].size})"
        report[:reported].each do |r|
          io.puts "  #{r[:key]} #{r[:kind]}: args (#{r[:args].join(', ')}) -> #{r[:outcome]} [#{r[:count]}x]#{r[:frame] ? " #{r[:frame]}" : ''}"
          r[:method_types].each { |t| io.puts "      #{t.size > 220 ? "#{t[0, 220]}..." : t}" }
        end
      end
      io.puts "", "written to #{report[:json] || 'evidence/repair.json'}"
    end
  end
end
