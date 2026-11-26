require_relative "../lib"
class Helper; end
s = Shelf.new
s.add(:sym)
s.first
s.add(Helper.new)
s.add(Class.new.new)
begin
  s.check(nil)
rescue ArgumentError
end
s.pick(1.5)
