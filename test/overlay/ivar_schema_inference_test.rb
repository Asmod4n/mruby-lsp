$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
require "mruby_lsp/type_inference"
require "mruby_lsp/completion" # type_of's AST arm (write inference) calls Completion.basic_type

TI = MrubyLsp::TypeInference

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

# Minimal index stub: only the ivar_type contract type_inference consults.
class StubIndex
  def initialize(map) = @map = map        # { [class, "@ivar"] => type name }
  def ivar_type(cls, ivar) = @map[[cls, ivar.to_s]]
end

def doc_for(src)
  pr  = Prism.parse(src)
  ast = Struct.new(:value, :comments).new(pr.value, pr.comments)
  Struct.new(:ast).new(ast)
end

# offset of the LAST `@ivar` READ (not a write) named `name`
def ivar_read_offset(root, name)
  off = nil
  visit = lambda do |n|
    return unless n.is_a?(Prism::Node)
    if n.is_a?(Prism::InstanceVariableReadNode) && n.name.to_s == name
      off = n.location.start_offset
    end
    n.compact_child_nodes.each { |c| visit.call(c) }
  end
  visit.call(root)
  off
end

def infer(src, name, schema)
  doc = doc_for(src)
  off = ivar_read_offset(doc.ast.value, name)
  TI.infer_variable(:ivar, name, off, doc, StubIndex.new(schema), 0)
end

# 1. No write in scope -> declared schema type is the baseline.
check.call("declared schema used when no write",
           infer("class Foo\n  def m\n    @s\n  end\nend\n", "@s", { ["Foo", "@s"] => "Socket" }),
           "Socket")

# 2. A live write in scope WINS over the declaration (as dynamic as Ruby).
check.call("live write beats declaration",
           infer("class Foo\n  def m\n    @s = \"hi\"\n    @s\n  end\nend\n", "@s", { ["Foo", "@s"] => "Socket" }),
           "String")

# 3. No write AND no declaration -> nil.
check.call("no write, no schema -> nil",
           infer("class Foo\n  def m\n    @s\n  end\nend\n", "@s", {}),
           nil)

# 4. Union resolves to nil in the index already, so inference yields nil here.
check.call("union declaration (index nil) -> nil",
           infer("class Bar\n  def m\n    @u\n  end\nend\n", "@u", { ["Bar", "@u"] => nil }),
           nil)

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
