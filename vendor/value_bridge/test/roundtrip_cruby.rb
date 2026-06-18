$LOAD_PATH.unshift "lib", "ext/value_bridge"
require "value_bridge/opaque"
require "value_bridge_ext"   # the built .so

RT = ValueBridge.method(:__roundtrip)
def eq(label, a, b); raise "FAIL #{label}: #{a.inspect} != #{b.inspect}" unless a == b; puts "ok  #{label}"; end

# scalars
eq "nil",   RT.call(nil),   nil
eq "true",  RT.call(true),  true
eq "false", RT.call(false), false
eq "int",   RT.call(42),    42
eq "neg",   RT.call(-7),    -7
eq "float", RT.call(3.5),   3.5

# strings: utf8 stays utf8, binary stays binary
u = RT.call("héllo")
eq "utf8 val", u, "héllo"
eq "utf8 enc", u.encoding, Encoding::UTF_8
b = RT.call("\xFF\x00\xFE".b)
eq "bytes val", b.bytes, [0xFF,0,0xFE]
eq "bytes enc", b.encoding, Encoding::ASCII_8BIT

# arrays + nesting
eq "array", RT.call([1, "x", [2, nil, true]]), [1, "x", [2, nil, true]]

# opaque: a type outside the vocabulary
r = RT.call(Rational(3,4))
raise "FAIL opaque class #{r.class}" unless r.is_a?(ValueBridge::Opaque)
eq "opaque name", r.name, "Rational"
eq "opaque from", r.from, :cruby

# opaque round-trips, preserving name + origin
mr = ValueBridge::Opaque.new("BigStruct", "raw", :mruby)
r2 = RT.call(mr)
eq "opaque rt class", r2.class, ValueBridge::Opaque
eq "opaque rt name",  r2.name, "BigStruct"
eq "opaque rt from",  r2.from, :mruby    # origin preserved, not relabeled :cruby

# strict typing: a String subclass / odd object still safe (no crash)
eq "symbol->opaque", RT.call(:hi).is_a?(ValueBridge::Opaque), true

puts "ALL CRUBY ROUNDTRIP TESTS PASSED"
