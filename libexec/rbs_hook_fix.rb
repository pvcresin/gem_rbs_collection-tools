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

  # The generated wrapper method:
  # - calls block_given? and Object.new without a receiver, which a
  #   BasicObject subclass sends to method_missing (Builder::XmlMarkup
  #   turned them into tags and the run hung): use the block parameter and
  #   ::Object;
  # - passes the gem a `proc { |*args, &b| ... }` in place of the caller's
  #   block, so block.arity is -1 and code that dispatches on it (thor's
  #   Actions#get, jwt's key finder, Thor::Group) takes another path: the
  #   wrapper answers arity, parameters and lambda? like the original.
  module GemTypesBlockShape
    def self.copy(wrapper, original)
      wrapper.define_singleton_method(:arity) { original.arity }
      wrapper.define_singleton_method(:parameters) { |*a, **k| original.parameters(*a, **k) }
      wrapper.define_singleton_method(:lambda?) { original.lambda? }
      wrapper
    end
  end

  module RBSHookSafeSource
    def hook_method_source(prefix, method_name, key, random:, params:)
      line, src = super
      blk = "block__#{random}"
      without = alias_names(method_name, random).last
      src = src.sub(/^    if block_given\?$/, "    if #{blk}")
               .sub("block_given: block_given?,", "block_given: !#{blk}.nil?,")
               .sub("wrapped_block = Object.new.instance_exec do", "wrapped_block = ::Object.new.instance_exec do")
               .sub("      result = __send__(:\"#{without}\", *args, &wrapped_block)",
                    "      ::GemTypesBlockShape.copy(wrapped_block, #{blk})\n      result = __send__(:\"#{without}\", *args, &wrapped_block)")
      [line, src]
    end
  end
  RBS::Test::Hook.singleton_class.prepend(RBSHookSafeSource)

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

  # rbs/test installs hooks when a class or module body ends (`:end`).
  # Methods a gem adds to an existing class without reopening it - a
  # top-level `def IPAddress` (a private Object method), `String.class_eval`
  # or `define_method` - never get hooked. Watch method additions on the
  # targets that already exist and install the tester for them then.
  if (tester = $gem_types_rbs_tester)
    sample_size = get_sample_size(ENV["RBS_TEST_SAMPLE_SIZE"] || "") rescue nil
    unchecked = (ENV["RBS_TEST_UNCHECKED_CLASSES"] || "").split(",").map(&:strip)
    unchecked.push(*to_double_class(ENV["RBS_TEST_DOUBLE_SUITE"])) rescue nil
    targets = (ENV["RBS_TEST_TARGET"] || "").split(",").map(&:strip).reject { |t| t.end_with?("*") || t.empty? }
    targets.each do |name|
      klass = (Object.const_get(name) rescue nil)
      next unless klass.is_a?(Module)
      next unless tester.env.module_name?(RBS::TypeName.parse("::#{name}"))

      watcher = Module.new do
        define_method(:method_added) do |m|
          super(m)
          next unless equal?(klass) && !Thread.current[:gem_types_installing]

          begin
            Thread.current[:gem_types_installing] = true
            tester.install!(klass, sample_size: sample_size, unchecked_classes: unchecked)
          ensure
            Thread.current[:gem_types_installing] = false
          end
        end
        define_method(:singleton_method_added) do |m|
          super(m)
          next unless equal?(klass) && !Thread.current[:gem_types_installing]

          begin
            Thread.current[:gem_types_installing] = true
            tester.install!(klass, sample_size: sample_size, unchecked_classes: unchecked)
          ensure
            Thread.current[:gem_types_installing] = false
          end
        end
      end
      klass.singleton_class.prepend(watcher)
    end
  end
end
