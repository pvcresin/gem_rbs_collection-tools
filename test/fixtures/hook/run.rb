require_relative "lib"
p Tag.new.tag!(:a) { |x| x.b }
p Disp.new.run { |a, b| [a, b] }
p Disp.new.run { |a| a }
p Disp.new.lam?(&->(x) { x })
blk = proc { 1 }
d = Disp.new
d.keep(&blk)
puts "kept_same=#{d.kept.equal?(blk)}"
