# Loaded by rbs_check.sh -o. Records RBS runtime type errors instead of
# raising them, so a whole test suite can run to the end.
# Output: <prefix>.errors.tsv  "<count>x<TAB><message><TAB>@ <first test frame>"
#         <prefix>.checked.tsv "<count><TAB><class> <method>"
#         <prefix>.errors.jsonl one JSON object per distinct error (see
#         GemTypesErrLog below), for `gem-types repair`
# For overload errors the message also shows argument classes, whether a
# block was given and how the call ended. Relies on rbs 4.x internals.
require "rbs/test"
require "json"
$__rbs_checked = Hash.new(0)
$__rbs_errs = Hash.new { |h, k| h[k] = [0, nil] }
$__rbs_errs_json = {}

# Machine-readable error records. Each line:
#   key:      "Foo::Bar#m" / "Foo::Bar.m"
#   kind:     the RBS::Test::Errors class name (ArgumentTypeError, ...)
#   slot:     { pos: req|opt|rest|trail|key|keyrest|return, index:, name:, block: bool }
#             (type errors only)
#   declared: the declared type; loc: { file:, start:, end: } its location
#             (character offsets in the signature file)
#   method_type / method_types (overloads): the declared method type(s)
#   value:    a description of the value (see .describe), args: of each
#             argument (overload and arity errors)
#   recv:     the receiver's class { c:, src:, anon: } (the module itself
#             for a singleton method)
#   outcome:  how the call ended: return | raise | break; exc: the exception
#   count, frame: the first test frame
module GemTypesErrLog
  KCLASS = ::Kernel.instance_method(:class)
  CAP = 5
  SAMPLE = 50
  TEST_DIR = %r{(\A|/)(test|spec|features)/}

  module_function

  def type_known?(env, name)
    tn = RBS::TypeName.parse("::#{name}")
    env.module_name?(tn) || env.interface_name?(tn) || env.type_alias_name?(tn)
  rescue StandardError
    false
  end

  def type_params(env, name)
    entry = env.class_decls[RBS::TypeName.parse("::#{name}")]
    entry.respond_to?(:type_params) ? entry.type_params.size : 0
  rescue StandardError
    0
  end

  # { c: class name (nil when anonymous), src: file defining it, known:
  #   declared in the loaded RBS, tp: number of type parameters, lit: the
  #   literal for small Symbol/Integer/String values, mod: the module when
  #   the value is a Class/Module, e:/k:/v: element/key/value classes of an
  #   Array, Set or Hash (at most CAP each; more: true when there were more)
  #   , sup: the nearest ancestor class declared in the RBS, anon: true
  #   for an anonymous class }
  def describe(env, val, depth = 0)
    klass = KCLASS.bind_call(val)
    d = class_info(env, klass)
    if val.is_a?(Module)
      d[:mod] = class_info(env, val)
    elsif [Symbol, Integer].include?(klass) || (klass == String && val.size <= 40 && val.valid_encoding?)
      d[:lit] = val.inspect
    end
    return d if depth.positive?

    if klass <= Array || (defined?(::Set) && klass <= ::Set)
      d[:e], d[:more] = elems(env, val.first(SAMPLE))
    elsif klass <= Hash
      d[:k], more_k = elems(env, val.keys.first(SAMPLE))
      d[:v], more_v = elems(env, val.values.first(SAMPLE))
      d[:more] = more_k || more_v
    end
    d.compact
  rescue StandardError, NotImplementedError
    { c: nil, anon: true, err: true }
  end

  def elems(env, vals)
    ds = vals.map { |v| describe(env, v, 1) }.uniq
    [ds.first(CAP), ds.size > CAP || nil]
  end

  def class_info(env, klass)
    name = klass.name
    d = if name.nil? || name.empty?
          { c: nil, anon: true, known: false }
        else
          { c: name, src: (Object.const_source_location(name)&.first rescue nil), known: type_known?(env, name) }
        end
    tp = name ? type_params(env, name) : 0
    d[:tp] = tp if tp.positive?
    unless d[:known]
      sup = (klass.is_a?(Class) ? klass.ancestors.grep(Class) : []).find do |a|
        a.name && a != klass && ![Object, BasicObject].include?(a) && type_known?(env, a.name)
      end
      d[:sup] = sup.name if sup
    end
    d.compact
  end

  def slot(fun, param, block)
    s = if (i = fun.required_positionals.index { _1.equal?(param) }) then { pos: "req", index: i }
        elsif (i = fun.optional_positionals.index { _1.equal?(param) }) then { pos: "opt", index: i }
        elsif fun.rest_positionals.equal?(param) then { pos: "rest" }
        elsif (i = fun.trailing_positionals.index { _1.equal?(param) }) then { pos: "trail", index: i }
        elsif (k = fun.required_keywords.find { |_, p| p.equal?(param) }&.first) then { pos: "key", name: k }
        elsif (k = fun.optional_keywords.find { |_, p| p.equal?(param) }&.first) then { pos: "key", name: k, optional: true }
        elsif fun.rest_keywords.equal?(param) then { pos: "keyrest" }
        else { pos: "?" }
        end
    s[:name] ||= param.name if param.respond_to?(:name) && param.name
    s.merge(block: block)
  end

  def loc(type)
    l = type.location or return nil
    { file: l.buffer.name.to_s, start: l.start_pos, end: l.end_pos }
  rescue StandardError
    nil
  end

  def record(tester, receiver, trace, err)
    env = tester.env
    mc = trace.method_call
    rec = { key: RBS::Test::Errors.method_tag(err)[1..-2], kind: err.class.name.split("::").last }
    rec[:recv] = class_info(env, tester.kind == :singleton ? receiver : KCLASS.bind_call(receiver)).slice(:c, :src, :anon)
    case err
    when RBS::Test::Errors::ArgumentTypeError, RBS::Test::Errors::BlockArgumentTypeError
      block = err.is_a?(RBS::Test::Errors::BlockArgumentTypeError)
      fun = block ? err.method_type.block.type : err.method_type.type
      rec.merge!(slot: slot(fun, err.param, block), declared: err.param.type.to_s, loc: loc(err.param.type),
                 method_type: err.method_type.to_s, value: describe(env, err.value))
    when RBS::Test::Errors::ReturnTypeError, RBS::Test::Errors::BlockReturnTypeError
      block = err.is_a?(RBS::Test::Errors::BlockReturnTypeError)
      rec.merge!(slot: { pos: "return", block: block }, declared: err.type.to_s, loc: loc(err.type),
                 method_type: err.method_type.to_s, value: describe(env, err.value))
    when RBS::Test::Errors::UnresolvedOverloadingError
      rec.merge!(method_types: err.method_types.map(&:to_s), args: (mc.arguments.map { describe(env, _1, 1) } rescue []),
                 block_given: trace.block_given)
    else
      rec.merge!(method_type: (err.method_type.to_s rescue nil), args: (mc.arguments.map { describe(env, _1, 1) } rescue []),
                 block_given: trace.block_given)
    end
    rec[:outcome] = mc.exception? ? "raise" : (mc.return? ? "return" : "break")
    rec[:exc] = mc.exception.class.name if mc.exception?
    id = JSON.generate(rec)
    ent = ($__rbs_errs_json[id] ||= [0, nil])
    ent[0] += 1
    ent[1] ||= caller.find { |l| l =~ TEST_DIR && l !~ %r{rbs/test|gem_types|libexec} }
  rescue StandardError => e
    warn "log_errors: could not record #{err.class}: #{e.class}: #{e.message}" if ENV["GEM_TYPES_DEBUG"]
  end
end
module RBSLogNoRaise
  def call(receiver, trace)
    $__rbs_checked["#{self_class rescue '?'} #{trace.method_name}"] += 1
    super
  rescue RBS::Test::Tester::TypeError => e
    e.errors.each do |err|
      GemTypesErrLog.record(self, receiver, trace, err)
      msg = RBS::Test::Errors.to_string(err) rescue err.inspect
      msg = msg.gsub(/#<[^>]{60,}>/) { |m| m[0, 60] + "...>" }
      if msg.include?("UnresolvedOverloading")
        mc = trace.method_call
        args = (mc.arguments.map { |a| "#{a.class}:#{a.inspect[0, 60]}" } rescue ["?"])
        blk = trace.block_given ? " +block" : ""
        out = mc.exception? ? "raise #{mc.exception.class}" : (mc.return? ? "#{mc.return_value.class}" : "break")
        msg += " args=(#{args.join(', ')})#{blk} -> #{out}"
      end
      key = msg[0, 400]
      ent = $__rbs_errs[key]; ent[0] += 1
      ent[1] ||= caller.find { |l| l =~ %r{/(test|spec|features)/} && l !~ /rbs\/test/ }
    end
    nil
  end
end
RBS::Test::Tester::MethodCallTester.prepend(RBSLogNoRaise)
# Every Ruby process of the run appends (rbs_check.sh clears the files first),
# so a test command that starts one process per test file is counted whole.
at_exit do
  out = ENV.fetch("RBS_ERR_OUT")
  append = lambda do |path, lines|
    next if lines.empty?

    File.open(path, "a") { |f| f.flock(File::LOCK_EX); f.puts(lines) }
  end
  append.(out + ".checked.tsv", $__rbs_checked.sort.map { |k, v| "#{v}\t#{k}" })
  append.(out + ".errors.jsonl", $__rbs_errs_json.map { |id, (n, loc)| JSON.generate(JSON.parse(id).merge("count" => n, "frame" => loc)) })
  append.(out + ".errors.tsv", $__rbs_errs.sort_by { |k, v| -v[0] }.map { |k, (n, loc)| "#{n}x\t#{k}\t@ #{loc}" })
end
