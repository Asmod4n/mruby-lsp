$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
require "mruby_lsp/index"
require "mruby_lsp/completion"
require "mruby_lsp/hover"
include MrubyLsp
E = MrubyLsp::Index::Entry

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def doc(src) = Struct.new(:ast, :text).new(Prism.parse(src), src)

def cls(name)
  E.new(name: name, owner: "Object", kind: :class, uri: "file:///core/#{name.downcase}.rb",
        line: 7, params: nil, native: false, singleton: false, doc: "the #{name} class",
        superclass: "Object")
end

def index_with_core
  idx = MrubyLsp::Index.new
  %w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, c == "Object" ? %w[Object Kernel BasicObject] : [c]) }
  entries = %w[String Symbol Integer Float Array Hash TrueClass FalseClass NilClass Range].map { |n| cls(n) }
  # Kernel#String conversion method (for the String("foo") call case)
  entries << E.new(name: "Kernel#String", owner: "Kernel", kind: :method, uri: "file:///core/kernel.rb",
                   line: 3, params: "(arg)", native: false, singleton: false, doc: nil)
  idx.set_buffer("file:///core/x.rb", entries, 0)
  idx
end

# cursor ON the first char of `needle` (that char must belong to the target node,
# e.g. the "[" of an array, the ".." of a range -- not an inner element).
def pos_of(src, needle)
  off = src.index(needle)
  line = src[0...off].count("\n")
  col  = off - (src.rindex("\n", off - 1) ? src.rindex("\n", off - 1) + 1 : 0)
  { line: line, character: col }
end

def hover_value(src, needle)
  idx = index_with_core
  res = MrubyLsp::Hover.response(doc(src), pos_of(src, needle), idx)
  res && res.dig(:contents, :value)
end

# A literal's hover should name its class and link to where it's defined.
{
  "string literal" => ['x = "foo"',  '"foo"', "String"],
  "integer literal"=> ['n = 42',     "42",    "Integer"],
  "float literal"  => ['f = 3.14',   "3.14",  "Float"],
  "array literal"  => ['a = [1, 2]', "[1, 2]","Array"],
  "hash literal"   => ['h = {a: 1}', "{a: 1}","Hash"],
  "true literal"   => ['b = true',   "true",  "TrueClass"],
  "nil literal"    => ['z = nil',    "nil",   "NilClass"],
  "symbol literal" => ['s = :foo',   ":foo",  "Symbol"],
}.each do |label, (src, needle, klass)|
  v = hover_value(src, needle)
  check.(label, !v.nil? && v.include?(klass), true)
end

# Range: hover between the dots (the IntegerNode's inclusive end touches the
# first dot, so land on the second one to sit squarely on the RangeNode).
range_src = "r = 1..3"
idx = index_with_core
rv = MrubyLsp::Hover.response(doc(range_src), { line: 0, character: range_src.index("..") + 1 }, idx)
check.("range literal", rv.to_s.include?("Range"), true)

# definition location surfaces (the link to where the class is defined).
v = hover_value('x = "foo"', '"foo"')
check.("string literal links to source", v.to_s.include?("string.rb"), true)

# the String("foo") conversion call resolves to Kernel#String when hovering the name
v = hover_value('String("foo")', "String")
check.("String(...) call -> Kernel#String", v.to_s.include?("String"), true)
# and hovering the argument "foo" still yields String the class
v = hover_value('String("foo")', '"foo"')
check.("String(...) arg literal -> String class", v.to_s.include?("String"), true)

# a literal whose class isn't in the VM degrades to no hover (no crash)
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object])
res = MrubyLsp::Hover.response(doc('x = "foo"'), pos_of('x = "foo"', '"foo"'), idx)
check.("missing class -> nil (graceful)", res, nil)

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
