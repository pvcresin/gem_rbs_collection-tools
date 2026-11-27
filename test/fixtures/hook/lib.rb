class Tag < BasicObject
  def initialize; @out = +""; end
  def method_missing(name, *args) = (@out << "<#{name}>"; self)
  def tag!(name, &blk) = (@out << "<#{name}>"; blk&.call(self); @out)
  def out = @out
end
class Disp
  def run(&blk) = blk.arity == 2 ? blk.call(1, 2) : blk.call(1)
  def lam?(&blk) = blk.lambda?
  def keep(&blk) = (@kept = blk)
  def kept = @kept
end
class Pre
  module Wrap
    def name=(v)
      super
      @wrapped = true
      v
    end
  end
  prepend Wrap
  def name=(v)
    @name = v
  end
  def name = @name
  def wrapped = @wrapped
end
