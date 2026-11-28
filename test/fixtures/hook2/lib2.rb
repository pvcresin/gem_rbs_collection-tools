# No class body: like a class a C extension defines.
Gen = Class.new do
  def size = 1
end
# Reopened in another file after its first body ended (mini_portile2:
# version.rb, then mini_portile.rb with initialize).
class Reopen
  VERSION = "1"
end

class Reopen
  def initialize(x) = @x = x
  def get = @x
end
