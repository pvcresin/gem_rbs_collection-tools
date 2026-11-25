# Loaded by rbs_check.sh after rbs/test/setup. rbs/test hooks a singleton
# method with `klass.method(name)`, which breaks on classes or modules that
# define their own `method` (e.g. XPath extends XPath::DSL, whose #method
# builds an expression). Use Kernel#method for those.
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
end
