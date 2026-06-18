def eq(label, a, b); raise "FAIL #{label}: #{a.inspect} != #{b.inspect}" unless a == b; puts "ok  #{label}"; end
RT = ->(x){ ValueBridge.__roundtrip(x) }

eq "nil",   RT.(nil),   nil
eq "true",  RT.(true),  true
eq "false", RT.(false), false
eq "int",   RT.(42),    42
eq "neg",   RT.(-7),    -7
eq "float", RT.(3.5),   3.5

u = RT.("héllo")            # valid UTF-8 -> stays text
eq "utf8 val", u, "héllo"
b = RT.("\xFF\x00\xFE")     # invalid UTF-8 -> bytes, preserved
eq "bytes val", b.bytes, [0xFF,0,0xFE]

eq "array", RT.([1, "x", [2, nil, true]]), [1, "x", [2, nil, true]]

# opaque: a Hash is outside the vocabulary -> Opaque (and proves no crash on a
# non-string/non-array type going through the strict producer)
h = RT.({a: 1})
raise "FAIL opaque class #{h.class}" unless h.is_a?(ValueBridge::Opaque)
eq "opaque name", h.name, "Hash"
eq "opaque from", h.from, :mruby

# opaque round-trips preserving origin
cr = ValueBridge::Opaque.new("BigStruct", "raw", :cruby)
r2 = RT.(cr)
eq "opaque rt name", r2.name, "BigStruct"
eq "opaque rt from", r2.from, :cruby   # origin kept, not relabeled :mruby

# symbol -> opaque (strict: never treated as a string)
eq "symbol->opaque", RT.(:hi).is_a?(ValueBridge::Opaque), true

puts "ALL MRUBY ROUNDTRIP TESTS PASSED"
