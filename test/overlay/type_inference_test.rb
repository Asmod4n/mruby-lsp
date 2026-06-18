$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "mruby_lsp/index"
require "mruby_lsp/completion"
require "mruby_lsp/hover"
require "mruby_lsp/buffer_harvester"
include MrubyLsp
E = MrubyLsp::Index::Entry

# Type inference funnels every stage (1: buffer AST, 2: irep via Entry#return_type,
# 3: C) into a bare class-name string, which feeds the SAME index lookup ruby-lsp
# uses for a KNOWN (non-guessed) receiver. mruby-lsp never name-guesses, so there
# is no "Guessed receiver" marker -- the user-visible output is just the resolved
# method, identical regardless of which stage produced the type. These tests pin
# both: the funnel's output, and that the rendered surface matches the known path.

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def doc(src) = Struct.new(:ast, :text).new(Prism.parse(src), src)
def call_named(d, name)
  found = nil
  v = lambda { |n| (found = n if n.is_a?(Prism::CallNode) && n.name == name); n.compact_child_nodes.each(&v) }
  v.call(d.ast.value)
  found
end

# A hand-built index: Widget (with irep/Stage-2 return types on its methods) and
# the core classes its return types resolve to. No VM, no reflect.so -- the
# return_type field stands in for whatever stage produced it.
def m(owner, name, rt: nil, params: "()", singleton: false)
  sep = singleton ? "." : "#"
  E.new(name: "#{owner}#{sep}#{name}", owner: owner, kind: :method, uri: "file:///vm.rb",
        line: 1, params: params, native: false, singleton: singleton, doc: nil,
        return_type: rt)
end
def cls(name, sup = "Object")
  E.new(name: name, owner: "Object", kind: :class, uri: "file:///vm.rb", line: 1,
        params: nil, native: false, singleton: false, doc: nil, superclass: sup)
end

def fresh
  idx = MrubyLsp::Index.new
  %w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, c == "Object" ? %w[Object Kernel BasicObject] : [c]) }
  idx.set_ancestors("String",  %w[String Comparable Object Kernel BasicObject])
  idx.set_ancestors("Integer", %w[Integer Comparable Object Kernel BasicObject])
  idx.set_ancestors("Array",   %w[Array Enumerable Object Kernel BasicObject])
  idx.set_ancestors("Widget",  %w[Widget Object Kernel BasicObject])
  idx.set_buffer("file:///vm.rb", [
    cls("Widget"),
    m("Widget", "label", rt: "String"),   # Stage 2: irep -> String
    m("Widget", "count", rt: "Integer"),  # Stage 2: irep -> Integer
    m("Widget", "tags",  rt: "Array"),     # Stage 2: irep -> Array
    m("Widget", "via",   rt: nil),         # send terminal -> unknown
    m("String", "upcase", rt: nil),        # C method -> unknown
    m("String", "length", rt: nil),
    m("String", "dup",    rt: "String"),   # rt fixture for the value-constant cascade
    m("Integer", "succ",  rt: nil),
  ], 0)
  idx
end

# ── A. funnel: receiver_type / infer_call yield the right bare class name ──────

idx = fresh
ti = MrubyLsp::TypeInference

d = doc(%(w = Widget.new\nx = w.label\n))
recv = call_named(d, :label).receiver            # local `w`
check.("local <- Foo.new                 ", Completion.receiver_type(recv, d, idx), "Widget")
check.("Stage 2 via Entry#return_type     ", ti.infer_call(call_named(d, :label), d, idx), "String")

d = doc(%(w = Widget.new\nn = w.count\n))
check.("Stage 2 -> Integer                ", ti.infer_call(call_named(d, :count), d, idx), "Integer")

d = doc(%(w = Widget.new\nt = w.tags\n))
check.("Stage 2 -> Array                  ", ti.infer_call(call_named(d, :tags), d, idx), "Array")

d = doc(%(w = Widget.new\nv = w.via\n))
check.("send terminal -> nil              ", ti.infer_call(call_named(d, :via), d, idx), nil)

d = doc(%(w = Widget.new\nu = w.label.upcase\n))   # chain: w.label(String).upcase(C)->nil
check.("chained known then C -> nil       ", ti.infer_call(call_named(d, :upcase), d, idx), nil)

d = doc(%(s = "hi".upcase\n))
check.("literal receiver basic_type       ", Completion.receiver_type(call_named(d, :upcase).receiver, d, idx), "String")

# Stage 1 (buffer def in the current doc) beats anything, per keystroke:
d = doc(%(class Widget\n  def label; 7; end\nend\nw = Widget.new\nx = w.label\n))
check.("Stage 1 buffer def wins over VM   ", ti.infer_call(call_named(d, :label), d, idx), "Integer")

# branch in a buffer def -> unsound -> nil (never guess)
d = doc(%(class Widget\n  def label; rand > 0.5 ? "a" : 1; end\nend\nx = Widget.new.label\n))
check.("branching buffer def -> nil       ", ti.infer_call(call_named(d, :label), d, idx), nil)

# ── B. dynamism: an edit in ANOTHER open tab is reflected (overlay twin wins) ──

idx2 = fresh
edit = %(class Widget\n  def label; 99; end\nend\n)               # widget.rb edited -> Integer
idx2.set_buffer("file:///widget.rb", BufferHarvester.harvest("file:///widget.rb", Prism.parse(edit).value, edit), 1)
main = doc(%(w = Widget.new\nx = w.label\n))                       # query from main.rb (no Widget here)
check.("cross-file edit reflected         ", ti.infer_call(call_named(main, :label), main, idx2), "Integer")
idx2.clear_buffer("file:///widget.rb")
check.("tab closed -> compiled type again ", ti.infer_call(call_named(main, :label), main, idx2), "String")

# ── C. ruby-lsp parity: identical user-visible output, no "guessed" marker ─────
# Completion on an inferred receiver lists the SAME methods as the known class.

idx = fresh
def col(s)
  off = s.index("§"); src = s.sub("§", "")
  before = src[0...off]; line = before.count("\n"); chr = off - (before.rindex("\n") || -1) - 1
  [Struct.new(:ast, :text).new(Prism.parse(src), src), { line: line, character: chr }]
end

d, pos = col(%(w = Widget.new\nw.l§\n))                            # inferred receiver
inferred = Completion.items(d, pos, idx).map { |i| i[:label] }.sort
d2, pos2 = col(%(Widget.new.l§\n))                                 # receiver type reached directly
known    = Completion.items(d2, pos2, idx).map { |i| i[:label] }.sort
check.("completion: inferred == known set ", inferred, known)
check.("completion lists the real method  ", inferred.include?("label"), true)
check.("no guessed-receiver leakage       ", inferred.any? { |l| l.downcase.include?("guess") }, false)

# Hover on an inferred-receiver method call resolves the method and carries no
# provenance/"guessed" text -- exactly ruby-lsp's known-type hover.
d, pos = col(%(w = Widget.new\nx = w.lab§el\n))
hov = MrubyLsp::Hover.response(d, pos, idx)
check.("hover resolves inferred method    ", !hov.nil?, true)
val = hov && hov.dig(:contents, :value).to_s
check.("hover mentions Widget#label       ", val.include?("label"), true) if hov
check.("hover has no 'Guessed' marker      ", (val || "").downcase.include?("guess"), false)

# ── D. literal-constant typing: a constant carries its value's type ───────────
ti = MrubyLsp::TypeInference
def D(s) = Struct.new(:ast, :text).new(Prism.parse(s), s)
def const_read(d, name)
  found = nil
  v = lambda { |n| (found = n if n.is_a?(Prism::ConstantReadNode) && n.name.to_s == name); n.compact_child_nodes.each(&v) }
  v.call(d.ast.value); found
end

dd = D(%(HEX = "0123abc"\nx = HEX\n))
check.("const = String literal -> String", ti.type_of(const_read(dd, "HEX"), dd, nil), "String")
dd = D(%(N = 42\nN\n))
check.("const = Integer literal -> Integer", ti.type_of(const_read(dd, "N"), dd, nil), "Integer")
dd = D(%(A = [1, 2]\nA\n))
check.("const = Array literal -> Array", ti.type_of(const_read(dd, "A"), dd, nil), "Array")
dd = D(%(W = Widget.new\nW\n))
check.("const = Foo.new -> Foo", ti.type_of(const_read(dd, "W"), dd, nil), "Widget")
# class constant (no value assignment) -> nil, NOT guessed as a class instance
dd = D(%(class Foo\nend\nFoo\n))
check.("class constant -> infer_constant nil", ti.infer_constant(const_read(dd, "Foo"), dd, nil), nil)
# nested namespace, matched by short name
dd = D(%(module M\n  K = "x"\nend\nM::K\n))
kc = nil; (v = lambda { |n| (kc = n if n.is_a?(Prism::ConstantPathNode)); n.compact_child_nodes.each(&v) }).call(dd.ast.value)
check.("nested const M::K -> String", ti.infer_constant(kc, dd, nil), "String")
# the cascade that motivated this: a value constant as an INSTANCE receiver
dd = D(%(HEX = "x"\ny = HEX.dup\n))
hexdup = nil; (v = lambda { |n| (hexdup = n if n.is_a?(Prism::CallNode) && n.name == :dup); n.compact_child_nodes.each(&v) }).call(dd.ast.value)
check.("value-const.dup routes to String#dup", ti.infer_call(hexdup, dd, idx), "String")

# ── E. singleton-context bare calls resolve to def self. siblings ─────────────
dd = D(%(module M\n  def self.a; "x"; end\n  def self.b; a; end\nend\n))
bdef = nil
(v = lambda { |n| (bdef = n if n.is_a?(Prism::DefNode) && n.name == :b); n.compact_child_nodes.each(&v) }).call(dd.ast.value)
check.("bare call to def self. sibling -> String", ti.infer_return(bdef, dd, nil, 0), "String")
# instance bare call still resolves to an instance def (not singleton)
dd = D(%(class K\n  def a; 1; end\n  def b; a; end\nend\n))
bdef2 = nil
(v = lambda { |n| (bdef2 = n if n.is_a?(Prism::DefNode) && n.name == :b); n.compact_child_nodes.each(&v) }).call(dd.ast.value)
check.("instance bare call -> instance def", ti.infer_return(bdef2, dd, nil, 0), "Integer")

# ── F. method params typed from an inline #: annotation ──────────────────────
# A parameter has no write node; its type comes from the def's annotation. The
# annotation's positionals (required then optional) line up with the def's.
pa = D(<<~RB)
  class << self
    #: (Socket) -> void
    def stream_socket(io, &block)
      io
    end
    #: (String, ?Numeric) -> void
    def stream_string(str, offset = 0, &block)
      str
      offset
    end
    def no_annotation(thing)
      thing
    end
    #: (Socket) -> void
    def reassigned(io)
      io = "s"
      io
    end
  end
RB
at = ->(needle) { pa.text.index(needle) }
check.("param io -> Socket",        ti.infer_local(:io,     at.("io\n"),     pa), "Socket")
check.("param str -> String",       ti.infer_local(:str,    at.("str\n"),    pa), "String")
check.("optional param -> Numeric", ti.infer_local(:offset, at.("offset\n"), pa), "Numeric")
check.("unannotated param -> nil",  ti.infer_local(:thing,  at.("thing\n"),  pa), nil)
r0 = pa.text.index("io = ")  # the reassigned use is the bare `io` AFTER the write
check.("reassignment beats annot",  ti.infer_local(:io, pa.text.index("io", r0 + 5), pa), "String")

puts "\n#{fail_count.zero? ? 'ALL PASS' : "#{fail_count} FAILED"}"
exit(fail_count.zero? ? 0 : 1)
