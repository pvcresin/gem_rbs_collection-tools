class Shelf
  def initialize = @items = []
  def add(item) = (@items << item; self)
  def first = @items.first
  def check(x) = (raise ArgumentError, "no nil" if x.nil?; x)
  def pick(x) = x
end
