require_relative "lib"
p Reg::Types.pub, Reg::Types.lazy?, Cache.load, Cache.new(1, 2).version
p Reg::Types.call_secret
$LOAD_PATH.unshift(__dir__)
require "lib2"
p Gen.new.size
