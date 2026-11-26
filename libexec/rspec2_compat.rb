# Lets RSpec 2 era specs run on RSpec 3 without editing them. Loaded with
# RUBYOPT=-r<this file> by gem-types when a suite fails with RSpec 2 APIs.
#   stub!/unstub!, mock/stub doubles, any_number_of_times, and_return(),
#   expect_with :stdlib (assert_*), and the old should syntax.
require "rspec/core"
require "rspec/mocks"
require "rspec/expectations"
begin
  require "test/unit/assertions"
rescue LoadError
  # test-unit is not in the bundle: no assert_* helpers.
end

RSpec.configure do |c|
  c.mock_with(:rspec) { |m| m.syntax = %i[should expect] }
  c.expect_with(:rspec) { |e| e.syntax = %i[should expect] }
  c.include Test::Unit::Assertions if defined?(Test::Unit::Assertions)
end

module RSpec2Compat
  # `expect_with :rspec, :stdlib`: RSpec 3 dropped :stdlib; the assertions
  # are included above, so keep only :rspec.
  module Configuration
    def expect_with(*frameworks, &block)
      frameworks -= %i[stdlib test_unit minitest]
      frameworks = [:rspec] if frameworks.empty?
      return if @expectation_frameworks && !@expectation_frameworks.empty? && block.nil? # already set
      super(*frameworks, &block)
    end
  end
  RSpec::Core::Configuration.prepend(Configuration)

  module ExampleMethods
    def mock(*args, &block) = double(*args, &block)
    def stub(*args, &block) = args.empty? || args.first.is_a?(String) || args.first.is_a?(Hash) ? double(*args, &block) : super
  end
  RSpec.configure { |c| c.include ExampleMethods }
end

RSpec::Mocks::Syntax.enable_should rescue nil
class Object
  def stub!(*args, &block) = stub(*args, &block)
  def unstub!(*args) = unstub(*args)
end
module RSpec2Compat
  module MessageExpectation
    # RSpec 3 removed at_least(0); the count check then always passes.
    def any_number_of_times
      __send__(:set_expected_received_count, :at_least, 0)
      self
    end

    # RSpec 2 allowed `and_return()` (returns nil).
    def and_return(*values, &block)
      values = [nil] if values.empty? && block.nil?
      super(*values, &block)
    end
  end
  RSpec::Mocks::MessageExpectation.prepend(MessageExpectation)
end
