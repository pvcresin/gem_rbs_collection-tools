# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

# libexec/env_gemfile.rb: the Gemfile a gem's own tests run with.
class EnvGemfileTest < Minitest::Test
  SCRIPT = File.expand_path("../libexec/env_gemfile.rb", __dir__)

  def test_jruby_only_gems_are_left_out
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "foo.gemspec"), <<~RUBY)
        Gem::Specification.new do |s|
          s.name = "foo"; s.version = "1.0"; s.summary = "x"; s.authors = ["x"]; s.files = []
        end
      RUBY
      _, st = Open3.capture2e("gem", "build", "foo.gemspec", chdir: dir)
      assert st.success?
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      File.write(File.join(repo, "gems.rb"), <<~RUBY)
        source "https://rubygems.org"
        gem "jruby-openssl" if defined? JRUBY_VERSION
        gem "jruby-launcher"
        platforms :jruby do
          gem "jar-dependencies"
        end
        gem "rspec", "~> 3.7"
      RUBY
      out, st = Open3.capture2e(RbConfig.ruby, SCRIPT, File.join(dir, "foo-1.0.gem"), repo)
      assert st.success?, out
      assert_includes out, %(gem "rspec", "~> 3.7")
      refute_match(/jruby|jar-dependencies/, out)
    end
  end
end
