$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "mruby_lsp/index"
require "mruby_lsp/completion"
require "mruby_lsp/hover"
include MrubyLsp
E = MrubyLsp::Index::Entry

# Locals born at BINDING SITES -- pattern-match captures (`in Integer => n`,
# `expr => x`), block params (`each do |e|`), numbered params (`_1`), and `it`
# -- type like assigned locals (issue #4). Same contract as every other
# inference path: a bare class name only when the buffer's AST proves it,
# nil otherwise (never guess).

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

ti = MrubyLsp::TypeInference
def D(s) = Struct.new(:ast, :text).new(Prism.parse(s), s)
# infer at the LAST occurrence of `needle` (the use, not the binding)
at = ->(d, name, needle = nil) { ti = MrubyLsp::TypeInference; ti.infer_local(name.to_sym, d.text.rindex(needle || name.to_s), d) }

# ── A. pattern-match captures ──────────────────────────────────────────────────

d = D(%(case v\nin Integer => n then n\nend\n))
check.("in Integer => n           -> Integer",  at.(d, :n), "Integer")

d = D(%(case v\nin {name: String => s} then s\nend\n))
check.("in {name: String => s}    -> String",   at.(d, :s), "String")

d = D(%(case v\nin [Integer => a, b] then a\nend\n))
check.("in [Integer => a, ..]     -> Integer",  at.(d, :a), "Integer")
check.("bare element binding b    -> nil",      at.(d, :b, "b]"), nil)

d = D(%(case v\nin {id:} then id\nend\n))
check.("shorthand {id:}           -> nil",      at.(d, :id), nil)

d = D(%(w = Widget.new\ncase w\nin x then x\nend\n))
check.("in x captures subject     -> Widget",   at.(d, :x), "Widget")

d = D(%(data = [1, 2]\ndata => y\ny\n))
check.("rightward => y            -> Array",    at.(d, :y), "Array")

d = D(%(case v\nin [first, *rest] then rest\nend\n))
check.("array *rest               -> Array",    at.(d, :rest), "Array")

d = D(%(case v\nin {**opts} then opts\nend\n))
check.("hash **opts               -> Hash",     at.(d, :opts), "Hash")

d = D(%(case v\nin 1..9 => n then n\nend\n))
check.("range pattern 1..9 => n   -> Integer",  at.(d, :n), "Integer")

d = D(%(case v\nin "id" => s then s\nend\n))
check.("literal pattern => s      -> String",   at.(d, :s), "String")

d = D(%(case v\nin /x/ => m then m\nend\n))
check.("regexp pattern matches String",         at.(d, :m), "String")

d = D(%(case v\nin Integer | Float => x then x\nend\n))
check.("alternation of two types  -> nil",      at.(d, :x), nil)

d = D(%(HEX = "abc"\ncase v\nin HEX => s then s\nend\n))
check.("value-constant pattern    -> String",   at.(d, :s), "String")

# each `in` branch types its own capture; usage in the second branch sees the
# second binding
d = D(%(case v\nin Integer => x then 0\nin String => x then x\nend\n))
check.("later branch rebinds x    -> String",   at.(d, :x, "x\n"), "String")

# ordering vs writes: the LATEST of write/binding wins, both ways
d = D(%(x = ""\ncase v\nin Integer => x then 0\nend\nx\n))
check.("binding after write wins  -> Integer",  at.(d, :x, "x\n"), "Integer")
d = D(%(case v\nin Integer => x then 0\nend\nx = ""\nx\n))
check.("write after binding wins  -> String",   at.(d, :x, "x\n"), "String")

# ── B. block parameters ────────────────────────────────────────────────────────

# Stage 1: the called method is a buffer def -> the type it yields
d = D(%(def each_widget\n  yield Widget.new\nend\neach_widget do |w|\n  w\nend\n))
check.("buffer def yield          -> Widget",   at.(d, :w, "w\nend"), "Widget")

# two agreeing yields -> the type; disagreeing yields -> nil
d = D(%(def pick\n  yield 1\n  yield 2\nend\npick { |n| n }\n))
check.("agreeing yields           -> Integer",  at.(d, :n, "n }"), "Integer")
d = D(%(def pick\n  yield 1\n  yield "s"\nend\npick { |n| n }\n))
check.("disagreeing yields        -> nil",      at.(d, :n, "n }"), nil)

# literal receivers
d = D(%([1, 2, 3].each do |e|\n  e\nend\n))
check.("[Int].each |e|            -> Integer",  at.(d, :e, "e\nend"), "Integer")
d = D(%([1, "a"].each { |e| e }\n))
check.("mixed array elements      -> nil",      at.(d, :e, "e }"), nil)
d = D(%(xs = ["a", "b"]\nxs.map { |s| s }\n))
check.("local <- [Str], .map |s|  -> String",   at.(d, :s, "s }"), "String")
d = D(%(NAMES = ["a"]\nNAMES.each { |s| s }\n))
check.("const <- [Str], .each |s| -> String",   at.(d, :s, "s }"), "String")
d = D(%((1..9).each { |i| i }\n))
check.("(1..9).each |i|           -> Integer",  at.(d, :i, "i }"), "Integer")

# hashes: |k, v| from the literal's keys/values; one param -> the pair
d = D(%({a: 1, b: 2}.each { |k, v| k }\n))
check.("hash each |k, _|          -> Symbol",   at.(d, :k, "k }"), "Symbol")
check.("hash each |_, v|          -> Integer",  at.(d, :v, "v| k"), "Integer")
d = D(%({a: 1}.each { |pair| pair }\n))
check.("hash each |pair|          -> Array",    at.(d, :pair, "pair }"), "Array")
d = D(%({a: 1}.each_key { |k| k }\n))
check.("each_key                  -> Symbol",   at.(d, :k, "k }"), "Symbol")
d = D(%({a: 1}.each_value { |v| v }\n))
check.("each_value                -> Integer",  at.(d, :v, "v }"), "Integer")
d = D(%({a: 1}.each_with_index { |pair, i| pair }\n))
check.("hash each_with_index pair -> Array",    at.(d, :pair, "pair }"), "Array")

# scalar receivers
d = D(%(5.times { |i| i }\n))
check.("5.times |i|               -> Integer",  at.(d, :i, "i }"), "Integer")
d = D(%(n = 3\nn.upto(9) { |i| i }\n))
check.("Integer local .upto |i|   -> Integer",  at.(d, :i, "i }"), "Integer")
d = D(%("abc".each_char { |c| c }\n))
check.("each_char                 -> String",   at.(d, :c, "c }"), "String")
d = D(%("abc".each_byte { |b| b }\n))
check.("each_byte                 -> Integer",  at.(d, :b, "b }"), "Integer")

# index/memo params
d = D(%(["a"].each_with_index { |s, i| i }\n))
check.("each_with_index |s, _|    -> String",   at.(d, :s, "s,"), "String")
check.("each_with_index |_, i|    -> Integer",  at.(d, :i, "i }"), "Integer")
d = D(%([1].each_with_object([]) { |e, acc| acc }\n))
check.("each_with_object memo     -> Array",    at.(d, :acc, "acc }"), "Array")

# an opaque receiver stays untyped -- never guess
d = D(%(def take(xs)\n  xs.each { |e| e }\nend\n))
check.("opaque receiver           -> nil",      at.(d, :e, "e }"), nil)

# a write inside the block beats the param type
d = D(%([1].each { |e| e = "s"\ne }\n))
check.("reassignment beats param  -> String",   at.(d, :e, "e }"), "String")

# numbered params and `it`
d = D(%([1, 2].map { _1 }\n))
check.("numbered _1               -> Integer",  at.(d, :_1, "_1 }"), "Integer")
d = D(%({a: 1}.each { _2 }\n))
check.("numbered _2 (hash value)  -> Integer",  at.(d, :_2, "_2 }"), "Integer")
d = D(%(["a"].map { it }\n))
check.("it                        -> String",   at.(d, :it, "it }"), "String")

# nested blocks: the innermost binding wins
d = D(%([[1]].each do |row|\n  ["a"].each { |x| x }\nend\n))
check.("inner block shadows       -> String",   at.(d, :x, "x }"), "String")

# ── C. the user-visible surface: completion + hover on bound locals ───────────

def cls(name, sup = "Object")
  E.new(name: name, owner: "Object", kind: :class, uri: "file:///vm.rb", line: 1,
        params: nil, native: false, singleton: false, doc: nil, superclass: sup)
end
def m(owner, name, rt: nil)
  E.new(name: "#{owner}##{name}", owner: owner, kind: :method, uri: "file:///vm.rb",
        line: 1, params: "()", native: false, singleton: false, doc: nil, return_type: rt)
end
idx = MrubyLsp::Index.new
%w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, c == "Object" ? %w[Object Kernel BasicObject] : [c]) }
idx.set_ancestors("Widget", %w[Widget Object Kernel BasicObject])
idx.set_buffer("file:///vm.rb", [cls("Widget"), m("Widget", "label", rt: "String")], 0)

def col(s)
  off = s.index("§"); src = s.sub("§", "")
  before = src[0...off]; line = before.count("\n"); chr = off - (before.rindex("\n") || -1) - 1
  [Struct.new(:ast, :text).new(Prism.parse(src), src), { line: line, character: chr }]
end

d, pos = col(%(w = Widget.new\ncase w\nin x\n  x.l§\nend\n))
items = Completion.items(d, pos, idx).map { |i| i[:label] }
check.("completion on pattern-bound local", items.include?("label"), true)

d, pos = col(%(def each_widget\n  yield Widget.new\nend\neach_widget { |w| w.l§ }\n))
items = Completion.items(d, pos, idx).map { |i| i[:label] }
check.("completion on typed block param", items.include?("label"), true)

# hover ON the capture target itself (offset inside the pattern) resolves too:
# hover.rb feeds the target's own start offset into the same infer_local funnel
src = %(case v\nin Integer => num then 0\nend\n)
d = D(src)
check.("hover funnel: capture target type", ti.infer_local(:num, src.index("num"), d), "Integer")

puts "\n#{fail_count.zero? ? 'ALL PASS' : "#{fail_count} FAILED"}"
exit(fail_count.zero? ? 0 : 1)
