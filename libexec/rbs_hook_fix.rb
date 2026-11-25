# Loaded by rbs_check.sh after rbs/test/setup. rbs/test hooks a singleton
# method with `klass.method(name)`, which breaks on classes or modules that
# define their own `method` (e.g. XPath extends XPath::DSL, whose #method
# builds an expression). Use Kernel#method for those.
# Also: RBS_TEST_ONLY_METHODS (below).
if defined?(RBS::Test::Hook)
  module RBSHookKernelMethod
    KERNEL_METHOD = ::Kernel.instance_method(:method)

    def hook_singleton_method(klass, method, key:)
      return super if KERNEL_METHOD.bind_call(klass, :method).owner == ::Kernel

      random = SecureRandom.hex(4)
      params = KERNEL_METHOD.bind_call(klass, method).parameters
      line, source = hook_method_source("#{klass}.", method, key, random: random, params: params)
      klass.singleton_class.module_eval(source, __FILE__, line)
      setup_alias_method_chain klass.singleton_class, method, random: random
    end
  end
  RBS::Test::Hook.singleton_class.prepend(RBSHookKernelMethod)

  # RBS_TEST_ONLY_METHODS="String#to_nfc,Kernel.ap": for the classes named
  # there, hook only those methods. Lets a gem's additions to core classes
  # be checked without wrapping every core method of String or Kernel.
  only = (ENV["RBS_TEST_ONLY_METHODS"] || "").split(",").map(&:strip).reject(&:empty?)
  unless only.empty?
    RBS_TEST_ONLY = only.to_h { |m| [m, true] }.freeze
    RBS_TEST_ONLY_CLASSES = only.map { |m| m[/\A(.+?)[#.][^#.]+\z/, 1] }.uniq.freeze
    module RBSHookOnlyMethods
      NAME = ::Module.instance_method(:name)

      def hook_instance_method(klass, method, key:)
        name = NAME.bind_call(klass)
        return if RBS_TEST_ONLY_CLASSES.include?(name) && !RBS_TEST_ONLY["#{name}##{method}"]

        super
      end

      def hook_singleton_method(klass, method, key:)
        name = NAME.bind_call(klass)
        return if RBS_TEST_ONLY_CLASSES.include?(name) && !RBS_TEST_ONLY["#{name}.#{method}"]

        super
      end
    end
    RBS::Test::Hook.singleton_class.prepend(RBSHookOnlyMethods)
  end
end
