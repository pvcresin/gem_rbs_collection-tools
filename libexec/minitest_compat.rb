# Old tests use the MiniTest constant, which minitest 6 removed (5.19+ kept
# it only with MT_COMPAT). Loaded with RUBYOPT=-r<this file> by gem-types.
# Resolves MiniTest lazily, so the bundle decides which minitest loads.
module MinitestCompat
  def const_missing(name)
    return super unless name == :MiniTest

    require "minitest"
    Object.const_set(:MiniTest, ::Minitest)
  end
end
Module.prepend(MinitestCompat)
