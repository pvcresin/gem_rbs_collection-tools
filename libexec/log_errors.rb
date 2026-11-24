# Loaded by rbs_check.sh -o. Records RBS runtime type errors instead of
# raising them, so a whole test suite can run to the end.
# Output: <prefix>.errors.tsv  "<count>x<TAB><message><TAB>@ <first test frame>"
#         <prefix>.checked.tsv "<count><TAB><class> <method>"
# For overload errors the message also shows argument classes, whether a
# block was given and how the call ended. Relies on rbs 4.x internals.
require "rbs/test"
$__rbs_checked = Hash.new(0)
$__rbs_errs = Hash.new { |h, k| h[k] = [0, nil] }
module RBSLogNoRaise
  def call(receiver, trace)
    $__rbs_checked["#{self_class rescue '?'} #{trace.method_name}"] += 1
    super
  rescue RBS::Test::Tester::TypeError => e
    e.errors.each do |err|
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
at_exit do
  File.write(ENV.fetch("RBS_ERR_OUT") + ".checked.tsv", $__rbs_checked.sort.map { |k, v| "#{v}\t#{k}" }.join("\n"))
  File.write(ENV.fetch("RBS_ERR_OUT") + ".errors.tsv", $__rbs_errs.sort_by { |k, v| -v[0] }.map { |k, (n, loc)| "#{n}x\t#{k}\t@ #{loc}" }.join("\n"))
end
