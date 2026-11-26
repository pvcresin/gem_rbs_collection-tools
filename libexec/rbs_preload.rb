# Loaded by rbs_check.sh before rbs/test/setup: keeps a handle on the
# Tester that setup creates (a local variable there), so rbs_hook_fix.rb
# can install hooks that setup's own `:end` trace never reaches.
require "rbs"
require "rbs/test"

module GemTypesTesterHandle
  def initialize(...)
    super
    $gem_types_rbs_tester = self
  end
end
RBS::Test::Tester.prepend(GemTypesTesterHandle)
