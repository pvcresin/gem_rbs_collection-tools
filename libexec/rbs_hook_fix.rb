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
      # initialize: keep the object on a construction stack while it runs,
      # so a method it calls on itself before setting its state (mime-types
      # reads #simplified inside MIME::Type#initialize) is not reported
      # like a user-visible type error.
      if method_name == :initialize
        src = src.sub("      result = __send__(:\"#{without}\", *args, &wrapped_block)",
                      "      result = ::GemTypesInit.during(self) { __send__(:\"#{without}\", *args, &wrapped_block) }")
                 .sub("      result = __send__(:\"#{without}\", *args)",
                      "      result = ::GemTypesInit.during(self) { __send__(:\"#{without}\", *args) }")
      end
      [line, src]
    end
  end
  RBS::Test::Hook.singleton_class.prepend(RBSHookSafeSource)

  module GemTypesInit
    def self.stack = (Thread.current[:gem_types_init] ||= [])

    def self.during(obj)
      stack.push(obj)
      yield
    ensure
      stack.pop
    end

    def self.constructing?(obj) = stack.any? { |o| o.equal?(obj) }
  end

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
    all = (ENV["RBS_TEST_TARGET"] || "").split(",").map(&:strip).reject(&:empty?)
    exact = all.reject { |t| t.end_with?("*") }
    prefixes = all.select { |t| t.end_with?("::*") }.map { |t| t.delete_suffix("*") }
    name_of = Module.instance_method(:name)
    watched = {}
    install = lambda do |klass|
      next if Thread.current[:gem_types_installing]

      begin
        Thread.current[:gem_types_installing] = true
        tester.install!(klass, sample_size: sample_size, unchecked_classes: unchecked)
      rescue StandardError
        nil
      ensure
        Thread.current[:gem_types_installing] = false
      end
    end
    declared = ->(n) { tester.env.module_name?(RBS::TypeName.parse("::#{n}")) rescue false }
    # Hooks wait until the class body that adds a method has ended, as
    # rbs/test's own :end hook does: `module_function :x` after `def x`
    # copies whatever x is then, and a hook installed mid-body made the
    # copy call a missing alias (terminal-table's Util.ansi_escape).
    open_bodies = []
    inside = ->(klass) { open_bodies.any? { |o| o.equal?(klass) || o.equal?(klass.singleton_class) } }
    TracePoint.new(:class, :end) do |tp|
      if tp.event == :class
        open_bodies.push(tp.self)
      else
        o = open_bodies.pop
        k = o.respond_to?(:singleton_class?) && o.singleton_class? ? (o.attached_object rescue nil) : o
        install.(k) if k && watched[k] && !inside.(k)
      end
    end.enable
    watch = lambda do |klass|
      next if watched[klass]

      watched[klass] = true
      watcher = Module.new do
        define_method(:method_added) do |m|
          super(m)
          install.(klass) if equal?(klass) && !inside.(klass)
        end
        define_method(:singleton_method_added) do |m|
          super(m)
          install.(klass) if equal?(klass) && !inside.(klass)
        end
      end
      klass.singleton_class.prepend(watcher)
    end
    target = ->(n) { n && (exact.include?(n) || prefixes.any? { |pre| n.start_with?(pre) }) }
    exact.each do |name|
      klass = (Object.const_get(name) rescue nil)
      next unless klass.is_a?(Module) && declared.(name)

      watch.(klass)
    end
    # Targets defined after this file loads: a class whose methods come
    # from `class << Foo` blocks outside its body, or `Foo = Struct.new`
    # (no class body, so rbs/test's :end hook never runs for it).
    if Module.private_method_defined?(:const_added) || Module.method_defined?(:const_added)
      Module.prepend(Module.new do
        define_method(:const_added) do |sym|
          super(sym)
          own = name_of.bind_call(self)
          full = equal?(Object) ? sym.to_s : (own && "#{own}::#{sym}")
          next unless target.(full) && declared.(full)

          klass = (const_get(sym, false) rescue nil)
          next unless klass.is_a?(Module)

          watch.(klass)
          # Foo = Struct.new(...) is complete now; `class Foo` still has its
          # body to run (installed when it ends).
          install.(klass) unless inside.(klass)
        end
      end)
    end
  end
end

# Checking every call is what makes a checked suite slow (http-cookie: 612k
# checks, 9.5 min). Calls of the same method with the same shape - receiver
# class, argument classes, block given, how the call ended and the classes
# its block got and returned - pass or fail the same way, so after
# GEM_TYPES_CHECK_SAME (default 20; 0 checks everything) of them the rest
# are skipped. Element types inside collections can still differ between
# such calls; rbs/test only samples those anyway.
if defined?(RBS::Test::Tester::MethodCallTester)
  module GemTypesCheckSample
    LIMIT = Integer(ENV.fetch("GEM_TYPES_CHECK_SAME", "20"))
    SEEN = Hash.new(0)
    KLASS = ::Kernel.instance_method(:class)
    @last = nil
    @last_skip = false

    def self.cls(v) = (KLASS.bind_call(v) rescue BasicObject)

    def self.shape(tester, trace)
      mc = trace.method_call
      ended = mc.exception? ? [:raise, cls(mc.exception)] : (mc.return? ? [:return, cls(mc.return_value)] : [:break])
      blk = trace.block_calls.first(3).map do |bc|
        [bc.arguments.map { cls(_1) }, bc.return? ? cls(bc.return_value) : :other]
      end
      [tester.self_class, tester.kind, trace.method_name, mc.arguments.map { cls(_1) }, trace.block_given, ended, blk]
    end

    # Once per trace (log_errors.rb asks too, before counting a check).
    def self.skip?(tester, trace)
      return false if LIMIT <= 0
      return @last_skip if @last.equal?(trace)

      @last = trace
      key = shape(tester, trace)
      @last_skip = (SEEN[key] += 1) > LIMIT
    rescue StandardError
      @last_skip = false
    end

    def call(receiver, trace)
      return nil if GemTypesCheckSample.skip?(self, trace)

      super
    end
  end
  RBS::Test::Tester::MethodCallTester.prepend(GemTypesCheckSample)
end

# rbs/test hooks only public singleton methods (klass.methods(false)), so a
# declared private singleton method (`private_class_method`, `private` in
# `class << self`) was never checked. Hook those as well.
if defined?(RBS::Test::Tester)
  module GemTypesPrivateSingletons
    def install!(klass, sample_size:, unchecked_classes:)
      super
      tester, set = singleton_testers[klass]
      return unless tester

      privates = klass.singleton_class.private_instance_methods(false)
      return if privates.empty?

      type_name = factory.type_name(klass.name).absolute!
      definition = builder.build_singleton(type_name)
      key = nil
      definition.methods.each do |name, method|
        next if set.include?(name) || !privates.include?(name) || skip_method?(type_name, method)

        unless key
          key = new_key(type_name, "SingletonChecker")
          RBS::Test::Observer.register(key, tester)
        end
        RBS::Test::Hook.hook_singleton_method(klass, name, key: key)
        set << name
      end
    rescue StandardError => e
      RBS.logger.info { "private singleton hooks for #{klass}: #{e.message}" }
    end
  end
  RBS::Test::Tester.prepend(GemTypesPrivateSingletons)
end
