require_relative "lib"
p Tag.new.tag!(:a) { |x| x.b }
p Disp.new.run { |a, b| [a, b] }
p Disp.new.run { |a| a }
p Disp.new.lam?(&->(x) { x })
blk = proc { 1 }
d = Disp.new
d.keep(&blk)
puts "kept_same=#{d.kept.equal?(blk)}"
pre = Pre.new
pre.name = "x"
puts "pre=#{pre.name},#{pre.wrapped}"
Named.new.value
s = Stream.new
e = s.each
puts "stream_rest=#{s.rest.size},#{e.to_a.size}"
