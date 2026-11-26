require_relative "lib"
p Reg::Types.pub, Reg::Types.lazy?, Cache.load, Cache.new(1, 2).version
p Reg::Types.call_secret
