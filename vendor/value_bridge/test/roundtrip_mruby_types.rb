def eq(l,a,b); raise "FAIL #{l}: #{a.inspect} != #{b.inspect}" unless a==b; puts "ok  #{l}"; end
RT = ->(x){ ValueBridge.__roundtrip(x) }
eq "symbol",     RT.(:hello), :hello
eq "sym utf8",   RT.(:héllo), :héllo
eq "hash",       RT.({"a"=>1, :b=>[2,3], 4=>nil}), {"a"=>1, :b=>[2,3], 4=>nil}
eq "empty hash", RT.({}), {}
eq "range incl", RT.(1..5), (1..5)
eq "range excl", RT.(1...5), (1...5)
big = 12345678901234567890123456789012345678
eq "bignum",     RT.(big), big
eq "neg bignum", RT.(-big), -big
eq "bignum cls", RT.(big).class, Integer
eq "nested",     RT.({list: [1, 2.5, :x, "y", (0..2)]}), {list: [1, 2.5, :x, "y", (0..2)]}
puts "ALL NEW-TYPE MRUBY ROUNDTRIPS PASSED"
