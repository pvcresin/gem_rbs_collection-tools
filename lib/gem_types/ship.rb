# frozen_string_literal: true

require "open3"
require "shellwords"

module GemTypes
  # The last mile for one gem's RBS in a gem_rbs_collection worktree: the
  # checks CI runs (bin/test, RuboCop, rbs parse, strict_rubocop_config.rb),
  # that only gems/<gem>/ changed, msg-check on the commit message, then the
  # commit (exactly that message, no trailers) and, with push, the push and
  # a check that the remote branch has the commit.
  module Ship
    module_function

    # Variables of the gem's test environment that would make bin/test
    # use the wrong bundle.
    STRIP = %w[BUNDLE_GEMFILE GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_BIN_PATH].freeze

    def run(workdir:, sig:, msg:, push: false, out: $stdout)
      sig = File.expand_path(sig)
      sigdir = File.directory?(sig) ? sig : File.dirname(sig)
      ver = File.basename(sigdir)
      gem = File.basename(File.dirname(sigdir))
      wt, ok = sh(nil, "git", "-C", sigdir, "rev-parse", "--show-toplevel")
      return fail!(out, "not in a git worktree: #{sigdir}") unless ok

      wt = wt.strip
      branch = sh(wt, "git", "rev-parse", "--abbrev-ref", "HEAD").first.strip
      return fail!(out, "on #{branch}: ship from the add-#{gem} / update-#{gem} branch") if %w[main master HEAD].include?(branch)

      text = File.read(msg, encoding: "UTF-8")
      step(out, "only gems/#{gem}/ changed") do
        lines = sh(wt, "git", "status", "--porcelain", "--untracked-files=all").first.lines.map(&:chomp)
        others = lines.map { _1[3..] }.reject { _1.start_with?("gems/#{gem}/") }
        next "nothing to commit" if lines.empty?
        others.empty? || "other changes: #{others.first(5).join(', ')}"
      end or return false
      step(out, "msg-check") do
        found = MsgCheck.run(text, sig: sigdir, gem: gem, workdir: workdir)
        found.each { |level, m| out.puts "    #{level == :error ? 'ERROR' : 'warn '} #{m}" }
        found.none? { _1.first == :error } || "fix the message"
      end or return false
      step(out, "bin/test gems/#{gem}/#{ver}") { sh(wt, "bin/test", "gems/#{gem}/#{ver}", quiet: true).last || "bin/test failed" } or return false
      step(out, "rubocop gems/#{gem}") { sh(wt, "bundle", "exec", "rubocop", "gems/#{gem}", quiet: true).last || "offenses" } or return false
      files = Dir[File.join(sigdir, "*.rbs")] + Dir[File.join(sigdir, "_test", "*.rbs")]
      step(out, "rbs parse") { sh(wt, "bundle", "exec", "rbs", "parse", *files, quiet: true).last || "parse error" } or return false
      step(out, "gems/#{gem}/.rubocop.yml") { File.exist?(File.join(wt, "gems", gem, ".rubocop.yml")) || "missing" } or return false
      sh(wt, "git", "add", "gems/#{gem}")
      step(out, "strict_rubocop_config.rb") do
        sh(wt, "ruby", ".github/workflows/pr_bot/strict_rubocop_config.rb", quiet: true).last || "rejected"
      end or return false
      step(out, "commit") do
        _, ok = sh(wt, "git", "commit", "-q", "-F", File.expand_path(msg))
        next "git commit failed" unless ok

        body = sh(wt, "git", "log", "-1", "--format=%B").first
        next "the commit message differs from #{msg} (a hook or template changed it)" unless body.rstrip == text.rstrip
        next "the commit has a trailer" if body.match?(/^(Co-authored-by|Signed-off-by):/i)

        true
      end or return false
      return true unless push

      step(out, "push origin #{branch}") do
        _, ok = sh(wt, "git", "push", "-q", "-u", "origin", branch)
        next "git push failed" unless ok

        head = sh(wt, "git", "rev-parse", "HEAD").first.strip
        remote = sh(wt, "git", "ls-remote", "origin", "refs/heads/#{branch}").first.split.first
        remote == head || "origin/#{branch} is #{remote.inspect}, HEAD is #{head}"
      end
    end

    def step(out, name)
      res = yield
      if res == true
        out.puts "ok    #{name}"
        true
      else
        out.puts "FAIL  #{name}: #{res}"
        false
      end
    end

    def fail!(out, msg)
      out.puts "FAIL  #{msg}"
      false
    end

    # [stdout, success]; quiet keeps the output unless the command fails.
    def sh(dir, *cmd, quiet: false)
      env = STRIP.to_h { [_1, nil] }
      opts = dir ? { chdir: dir } : {}
      o, s = Open3.capture2e(env, *cmd, **opts)
      $stdout.puts o.lines.last(30).join if quiet && !s.success?
      [o, s.success?]
    end
  end
end
