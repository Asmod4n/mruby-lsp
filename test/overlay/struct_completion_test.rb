$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
%w[index locator completion type_inference buffer_harvester].each { |f| require "mruby_lsp/#{f}" }

# `Foo = Struct.new(:a, :b)` / `Foo = Data.define(:a, :b)` define a real class in
# the EDITOR (none of it is compiled into the VM). The buffer harvester must
# surface that class with its member accessors so `f.` completes — previously it
# was harvested as a plain constant and `f.` produced nothing.

fails = 0
check = lambda do |label, ok, detail = nil|
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        #{detail}" if !ok && detail
end

def harvest(src)
  ast = Prism.parse(src)
  idx = MrubyLsp::Index.new
  MrubyLsp::BufferHarvester.harvest("file:///t.rb", ast.value, src).each { |e| idx.add(e) }
  [Struct.new(:ast, :text).new(ast, src), idx]
end

def labels_at(src, line, char)
  doc, idx = harvest(src)
  MrubyLsp::Completion.items(doc, { line: line, character: char }, idx).map { |i| i[:label] }
end

# Struct: reader AND writer per member (Struct is mutable).
src = "Foo = Struct.new(:foo, :bar)\nf = Foo.new(1, [2,3])\nf.\n"
labels = labels_at(src, 2, 2)
check.("Struct member readers complete", (%w[foo bar] - labels).empty?, labels.inspect)
check.("Struct member writers complete", (%w[foo= bar=] - labels).empty?, labels.inspect)

# the constant is harvested as a CLASS (so it has methods / ancestry), not a
# bare :constant.
_, idx = harvest(src)
foo = idx.definitions("Foo").first
check.("Foo is a class entry", foo && foo.kind == :class, foo && foo.kind)
check.("Foo's superclass is Struct", foo && foo.superclass == "Struct", foo && foo.superclass)

# Data: readers only (Data instances are immutable).
dsrc = "Point = Data.define(:x, :y)\np = Point.new(1, 2)\np.\n"
dlabels = labels_at(dsrc, 2, 2)
check.("Data member readers complete", (%w[x y] - dlabels).empty?, dlabels.inspect)
check.("Data has NO member writers", (dlabels & %w[x= y=]).empty?, dlabels.inspect)

# A block body defines further methods into the class; keyword_init: is not a member.
bsrc = "Vec = Struct.new(:a, :b, keyword_init: true) do\n  def mag; a + b; end\nend\nv = Vec.new(a: 1, b: 2)\nv.\n"
blabels = labels_at(bsrc, 4, 2)
check.("block method completes", blabels.include?("mag"), blabels.inspect)
check.("members from a keyword_init Struct complete", (%w[a b] - blabels).empty?, blabels.inspect)
check.("keyword_init: is not harvested as a member", !blabels.include?("keyword_init"), blabels.inspect)

def entries(src)
  MrubyLsp::BufferHarvester.harvest("file:///t.rb", Prism.parse(src).value, src)
end

def entry(src, name)
  entries(src).find { |e| e.name == name }
end

# Struct.new("Named", :a) — the leading STRING names the class (Struct::Named in
# mruby), it is NOT a member. (Regression: an earlier cut harvested S#Named.)
ssrc = "S = Struct.new(\"Named\", :a, :b)\ns = S.new(1, 2)\ns.\n"
slabels = labels_at(ssrc, 2, 2)
check.("string-named Struct: members complete", (%w[a b] - slabels).empty?, slabels.inspect)
check.("string-named Struct: name is NOT a member", !slabels.include?("Named"), slabels.inspect)

# Foo = Class.new(Base) do … end -> class Foo < Base; block methods are Foo's,
# NOT Object's (the bare-constant path used to leak them to Object).
csrc = "Foo = Class.new(Object) do\n  def greet; end\nend\nf = Foo.new\nf.\n"
clabels = labels_at(csrc, 4, 2)
check.("Class.new: block method completes on instance", clabels.include?("greet"), clabels.inspect)
foo = entry(csrc, "Foo")
check.("Class.new: Foo is a class < Object", foo && foo.kind == :class && foo.superclass == "Object",
       foo && [foo.kind, foo.superclass].inspect)
check.("Class.new: method is NOT on Object", entry(csrc, "Object#greet").nil?)

# Mod = Module.new do … end -> module with its methods.
msrc = "Mod = Module.new do\n  def helper; end\nend\n"
m = entry(msrc, "Mod")
check.("Module.new: Mod is a module", m && m.kind == :module, m && m.kind)
check.("Module.new: method belongs to Mod", entry(msrc, "Mod#helper"))

# Foo ||= Struct.new(:a) — the ||= form is harvested too.
osrc = "Conf ||= Struct.new(:val)\nc = Conf.new(1)\nc.\n"
olabels = labels_at(osrc, 2, 2)
check.("||= Struct: member completes", olabels.include?("val"), olabels.inspect)
check.("||= plain constant is harvested", entry("CFG ||= 5\n", "CFG")&.kind == :constant)

# Multiple assignment: each constant target is a constant.
mw = entries("A, B = 1, 2\n").select { |e| e.kind == :constant }.map(&:name).sort
check.("multi-assign harvests both constants", mw == %w[A B], mw.inspect)

# include inside a Struct block registers as a mixin on the class.
isrc = "P = Struct.new(:x) do\n  include Comparable\n  def <=>(o); x <=> o.x; end\nend\n"
p = entry(isrc, "P")
check.("Struct block include -> mixin on class", p && p.mixins.include?([:include, "Comparable"]),
       p && p.mixins.inspect)

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
