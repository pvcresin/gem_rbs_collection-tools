module Reg
  class Types
    def self.pub = 1
  end
end
class << Reg::Types
  def lazy? = 2
  private
  def helper = 3
end
Cache = Struct.new(:version, :data)
class << Cache
  def load = 4
end
class Reg::Types
  class << self
    private def secret = 5
  end
  def self.call_secret = secret
end
