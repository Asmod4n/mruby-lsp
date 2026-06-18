$LOAD_PATH.unshift "lib", "ext/value_bridge"
require "value_bridge/opaque"; require "value_bridge_ext"
RT = ValueBridge.method(:__roundtrip)
def eq(l,a,b); raise "FAIL #{l}: #{a.inspect} != #{b.inspect}" unless a==b; puts "ok  #{l}"; end
eq "symbol",      RT.(:hello), :hello
eq "sym utf8",    RT.(:héllo), :héllo
eq "hash",        RT.({"a"=>1, :b=>[2,3], 4=>nil}), {"a"=>1, :b=>[2,3], 4=>nil}
eq "empty hash",  RT.({}), {}
eq "range incl",  RT.(1..5), (1..5)
eq "range excl",  RT.(1...5), (1...5)
eq "range str",   RT.("a".."z"), ("a".."z")
big = 12345678901234567890123456789012345678
eq "bignum",      RT.(big), big
eq "neg bignum",  RT.(-big), -big
eq "bignum class",RT.(big).class, Integer
eq "nested",      RT.({list: [1, 2.5, :x, "ext/value_bridge", (0..2)]}), {list: [1, 2.5, :x, "y", (0..2)]}
puts "ALL NEW-TYPE CRUBY ROUNDTRIPS PASSED"
