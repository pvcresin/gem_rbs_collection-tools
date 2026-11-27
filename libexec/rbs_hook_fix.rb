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

  # A class that prepends a module wrapping its own methods with `super`
  # (Addressable::URI prepends RestoreOnFailure): rbs/test aliases in the
  # class, alias_method picks up the prepended method, and its `super` reaches
  # the hook again (SystemStackError). Hook the prepended module instead, so
  # the check wraps what callers call.
  module RBSHookPrepended
    def hook_instance_method(klass, method, key:)
      owner = klass.instance_method(method).owner
      ancestors = klass.ancestors
      if owner != klass && owner.instance_of?(Module) && ancestors.index(owner) < ancestors.index(klass)
        return super(owner, method, key: key)
      end

      super
    end
  end
  RBS::Test::Hook.singleton_class.prepend(RBSHookPrepended)

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
      # eval("self", block.binding) (docile's fallback to the caller) must
      # see the caller, not the object the wrapper was built in.
      wrapper.define_singleton_method(:binding) { original.binding }
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
               # A DSL object that undefines equal?/instance_exec (factory_bot's
               # DefinitionProxy) as the block's self: use BasicObject's.
               .sub("block_result = if self.equal?(new_object)",
                    "block_result = if ::BasicObject.instance_method(:equal?).bind_call(self, new_object)")
               .sub("self.instance_exec(*block_args, &#{blk})",
                    "::BasicObject.instance_method(:instance_exec).bind_call(self, *block_args, &#{blk})")
      # RBS_TEST_RAW_BLOCKS="Foo#on,Foo.register": methods that keep the
      # block for later (`@callbacks << blk`). The wrapper proc only records
      # calls made before the method returns, so wrapping such a block
      # checks nothing and breaks code and tests that compare it with the
      # caller's block (factory_bot's definition blocks, `expect(x.block)
      # .to eq(blk)`): pass the caller's block itself.
      if GemTypesRawBlocks.raw?("#{prefix}#{method_name}")
        src = src.sub("      result = __send__(:\"#{without}\", *args, &wrapped_block)",
                      "      result = __send__(:\"#{without}\", *args, &#{blk})")
      end
      # initialize: keep the object on a construction stack while it runs,
      # so a method it calls on itself before setting its state (mime-types
      # reads #simplified inside MIME::Type#initialize) is not reported
      # like a user-visible type error.
      if method_name == :initialize
        src = src.sub(/^      result = __send__\(:"#{Regexp.escape(without.to_s)}", \*args, &(\w+)\)$/) do
          "      result = ::GemTypesInit.during(self) { __send__(:\"#{without}\", *args, &#{$1}) }"
        end
                 .sub("      result = __send__(:\"#{without}\", *args)",
                      "      result = ::GemTypesInit.during(self) { __send__(:\"#{without}\", *args) }")
      end
      [line, src]
    end
  end
  RBS::Test::Hook.singleton_class.prepend(RBSHookSafeSource)

  module GemTypesRawBlocks
    LIST = (ENV["RBS_TEST_RAW_BLOCKS"] || "").split(",").map(&:strip).reject(&:empty?).to_h { [_1, true] }.freeze
    def self.raw?(name) = LIST.key?(name)
  end

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
    watched = {}.compare_by_identity
    is_module = Module.instance_method(:is_a?)
    mod_name = ->(o) { (is_module.bind_call(o, Module) && name_of.bind_call(o)) rescue nil }
    target = ->(n) { n && (exact.include?(n) || prefixes.any? { |pre| n.start_with?(pre) }) }
    # `class << Foo` outside Foo's own body (mime-types' class << MIME::Types):
    # rbs/test installs hooks when a class body ends, but this body's self is
    # Foo's singleton class, so Foo's new singleton methods were never
    # hooked. Install for Foo when such a body ends. Only module receivers:
    # `class << self` inside an instance method has an object there (a
    # BasicObject one whose #hash is a tag in Builder::XmlMarkup).
    # A `class << self` inside Foo's own body (thor's class Thor) ends while
    # Foo is still being defined: rbs/test installs Foo's hooks when Foo's
    # body ends, so only act when that body is not open.
    open_bodies = []
    TracePoint.new(:class, :end) do |tp|
      o = tp.self
      if tp.event == :class
        open_bodies.push(o)
        next
      end
      open_bodies.pop
      next unless (o.singleton_class? rescue false)

      k = (o.attached_object rescue nil)
      n = mod_name.(k)
      next unless target.(n) && declared.(n)
      next if open_bodies.any? { |b| b.equal?(k) }

      install.(k)
    end.enable
    watch = lambda do |klass|
      next if watched[klass]

      watched[klass] = true
      watcher = Module.new do
        define_method(:method_added) do |m|
          super(m)
          install.(klass) if equal?(klass)
        end
        define_method(:singleton_method_added) do |m|
          super(m)
          install.(klass) if equal?(klass)
        end
      end
      klass.singleton_class.prepend(watcher)
    end
    exact.each do |name|
      klass = (Object.const_get(name) rescue nil)
      next unless klass.is_a?(Module) && declared.(name)

      watch.(klass)
    end
    # (A Module#const_added watcher for Foo = Struct.new classes was tried:
    # prepending const_added on Module broke thor's spec loading. A
    # Struct class reopened with `class << Foo` is covered above.)
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

      type_name = factory.type_name(GemTypesModuleName::NAME.bind_call(klass)).absolute!
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

  # Tester#install! looks the class up by klass.name, which a class may
  # override (rubyzip's ExtraField::Generic.name returns a Symbol): the
  # install raised and none of its methods were checked. Use Module#name.
  module GemTypesModuleName
    NAME = ::Module.instance_method(:name)

    def install!(klass, **kw)
      Thread.current[:gem_types_install_name] = NAME.bind_call(klass)
      super
    ensure
      Thread.current[:gem_types_install_name] = nil
    end
  end
  RBS::Test::Tester.prepend(GemTypesModuleName)

  module GemTypesFactoryName
    def type_name(string)
      real = Thread.current[:gem_types_install_name]
      super(real && !string.is_a?(String) ? real : string)
    end
  end
  RBS::Factory.prepend(GemTypesFactoryName)

  # The error tag ("[Foo#bar]") uses klass.name too.
  module GemTypesErrorTag
    def method_tag(error)
      tag = super
      return tag if error.klass.singleton_class?

      tag.sub(/\A\[[^#]*#/) { "[#{GemTypesModuleName::NAME.bind_call(error.klass)}#" }
    end
  end
  RBS::Test::Errors.singleton_class.prepend(GemTypesErrorTag)
end

# rbs/test checks a returned Enumerator by running it. For one of unknown
# size (`to_enum(:each)` over a stream: rubyzip's InputStream#each) that
# reads what the caller has not read yet, and the caller then gets nothing.
# Such an Enumerator is checked by class only.
if defined?(RBS::Test::TypeCheck)
  module GemTypesUnsizedEnumerator
    def value(val, type)
      if type.is_a?(RBS::Types::ClassInstance) && type.name.to_s.delete_prefix("::") == "Enumerator" &&
         ::Enumerator === val && (val.size.nil? rescue true)
        return true
      end

      super
    end
  end
  RBS::Test::TypeCheck.prepend(GemTypesUnsizedEnumerator)
end

# rbs/test keeps the original method as a public `name__without__RBS_TEST_...`
# alias (and the wrapper as `name__with__...`). Specs that list a class's
# public methods (addressable calls every reader of a frozen URI) found and
# called them. Make both aliases private: the wrapper calls the original
# with __send__, and the hooked name keeps the original's visibility.
if defined?(RBS::Test::Hook)
  module GemTypesPrivateAliases
    def setup_alias_method_chain(klass, target, random:)
      super
      names = alias_names(target, random)
      klass.instance_eval { private(*names) }
    end
  end
  RBS::Test::Hook.singleton_class.prepend(GemTypesPrivateAliases)
end
