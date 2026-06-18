$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
require "mruby_lsp/index"
require "mruby_lsp/completion"
require "mruby_lsp/type_inference"
require "mruby_lsp/scope_resolver"
include MrubyLsp
E = MrubyLsp::Index::Entry
TI = MrubyLsp::TypeInference

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def m(owner, name, rt: nil)
  E.new(name: "#{owner}##{name}", owner: owner, kind: :method, uri: "file:///vm.rb",
        line: 1, params: "()", native: true, singleton: false, doc: nil, return_type: rt)
end
def cls(name, sup = "Object")
  E.new(name: name, owner: "Object", kind: :class, uri: "file:///vm.rb", line: 1,
        params: nil, native: false, singleton: false, doc: nil, superclass: sup)
end
def doc(s) = Struct.new(:ast, :text).new(Prism.parse(s), s)
def call_named(d, name)
  found = nil
  v = lambda { |n| (found = n if n.is_a?(Prism::CallNode) && n.name == name); n.compact_child_nodes.each(&v) }
  v.call(d.ast.value)
  found
end

# Index: IO defines read (C method, no irep type); File and Socket inherit it.
idx = MrubyLsp::Index.new
%w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, c == "Object" ? %w[Object Kernel BasicObject] : [c]) }
idx.set_ancestors("IO",     %w[IO Object Kernel BasicObject])
idx.set_ancestors("File",   %w[File IO Object Kernel BasicObject])
idx.set_ancestors("Socket", %w[Socket IO Object Kernel BasicObject])
idx.set_ancestors("String", %w[String Comparable Object Kernel BasicObject])
idx.set_buffer("file:///vm.rb", [
  cls("IO"), cls("File", "IO"), cls("Socket", "IO"), cls("String"),
  m("IO", "read", rt: nil),         # C method, irep gave nothing
  m("String", "bytesize", rt: "Integer"),
], 0)

# The harvester observed read through a File receiver -> "File#read".
idx.merge_test_types({ "File#read" => "String?" })

read_entry = idx.visible_methods("IO").find { |e| e.name == "IO#read" }

# ── reconciliation: observed File#read re-keyed to the defining IO#read ───────
check.("c_return_type fallback on IO#read", idx.c_return_type(read_entry), "String?")
sock_read = idx.visible_methods("Socket").find { |e| e.name == "IO#read" }
check.("applies to Socket via ancestry",    idx.c_return_type(sock_read), "String?")

# ── full chain: io:Socket -> io.read -> String? ──────────────────────────────
d = doc(%(io = Socket.new\nr = io.read\n))
check.("io.read infers String?", TI.infer_call(call_named(d, :read), d, idx), "String?")

# ── narrowing: a nilable receiver resolves to its concrete class ──────────────
check.("concrete_receiver String? -> String", TI.concrete_receiver("String?"), "String")
check.("concrete_receiver bare passes",       TI.concrete_receiver("Integer"), "Integer")
check.("concrete_receiver union -> nil",      TI.concrete_receiver("(Integer | String)"), nil)
check.("concrete_receiver nilable union -> nil", TI.concrete_receiver("(Integer | String)?"), nil)
check.("concrete_receiver nil-in -> nil",     TI.concrete_receiver(nil), nil)

# ── receiver_type now narrows centrally, so EVERY consumer (completion, hover,
#    definition, signature help) resolves doc(String?) on String ───────────────
d = doc(%(io = Socket.new\ndoc = io.read\ndoc\n))
docnode = nil
v = lambda { |n| (docnode = n if n.is_a?(Prism::LocalVariableReadNode) && n.name == :doc); n.compact_child_nodes.each(&v) }
v.call(d.ast.value)
owner = Completion.receiver_type(docnode, d, idx)
check.("receiver_type narrows doc (String?) -> String", owner, "String")
check.("String#bytesize resolvable on the narrowed owner",
  idx.visible_methods(owner).any? { |e| e.name == "String#bytesize" }, true)

# ── the hover / go-to-def / signature-help path routes through
#    ScopeResolver.methods_for_receiver, which must hand the index to
#    receiver_type or the harvested type never resolves (the bug: hover & F12
#    found nothing while completion worked, because only completion passed it) ─
d = doc(%(io = Socket.new\ndoc = io.read\ndoc.bytesize\n))
bytesize_recv = call_named(d, :bytesize).receiver
ms = ScopeResolver.methods_for_receiver("bytesize", bytesize_recv, idx, d)
check.("methods_for_receiver resolves doc(String?) -> String#bytesize",
  (ms || []).any? { |e| e.name == "String#bytesize" }, true)

puts
puts "harvested_types failing=#{fail_count}/#{11}"
exit(fail_count.zero? ? 0 : 1)
