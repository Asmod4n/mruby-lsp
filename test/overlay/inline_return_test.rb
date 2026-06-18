$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
require "mruby_lsp/type_inference"
require "mruby_lsp/completion" # type_of's AST arm calls Completion.basic_type

TI = MrubyLsp::TypeInference

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

# A document twin matching what the buffer harvester builds: ast.value + comments.
def doc_for(src)
  pr  = Prism.parse(src)
  ast = Struct.new(:value, :comments).new(pr.value, pr.comments)
  Struct.new(:ast).new(ast)
end

def first_def(node)
  return node if node.is_a?(Prism::DefNode)
  node&.compact_child_nodes&.each do |c|
    r = first_def(c)
    return r if r
  end
  nil
end

def infer(src)
  doc  = doc_for(src)
  defn = first_def(doc.ast.value)
  TI.infer_return(defn, doc, nil, 0)
end

# 1. annotation return wins over the AST-inferred terminal (42 would be Integer)
check.call("annotation -> String beats AST Integer",
           infer("#: (Integer) -> String\ndef f(x)\n  42\nend\n"), "String")

# 2. no annotation: AST inference still works (regression guard)
check.call("no annotation -> AST infers String",
           infer("def g\n  \"hi\"\nend\n"), "String")

# 3. void return annotation yields no concrete class -> falls through to AST
check.call("void annotation falls through to AST Integer",
           infer("#: (Integer) -> void\ndef h(x)\n  1\nend\n"), "Integer")

# 4. fully-qualified annotation return passes through as-written
check.call("annotation -> ::Foo::Bar as written",
           infer("#: () -> ::Foo::Bar\ndef k\n  nil\nend\n"), "::Foo::Bar")

# 5. annotation two lines up (blank between) is NOT the line directly above ->
#    only the immediately-preceding comment line counts (param path semantics)
check.call("annotation not directly above -> AST wins",
           infer("#: () -> String\n\ndef m\n  1\nend\n"), "Integer")

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
