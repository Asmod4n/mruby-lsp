$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
%w[index locator completion type_inference buffer_harvester hover].each { |f| require "mruby_lsp/#{f}" }
E = MrubyLsp::Entry

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def index_with_core
  idx = MrubyLsp::Index.new
  %w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, [c, "Object", "Kernel", "BasicObject"].uniq) }
  %w[Hash String Integer Array Float].each do |n|
    idx.add(E.new(name: n, owner: "Object", kind: :class, uri: "file:///core/#{n.downcase}.rb",
                  line: 1, params: nil, native: false, singleton: false, doc: "the #{n}", superclass: "Object"))
  end
  idx
end

def title(doc, idx, line, needle, into: 1)
  col = doc.text.lines[line].index(needle) + into
  v = MrubyLsp::Hover.response(doc, { line: line, character: col }, idx)
  v && v.dig(:contents, :value).lines.reject { |l| l.strip.empty? || l.start_with?("```") }.first&.strip
end

src = <<~RB
  payload = { "a" => "hello", "b" => 42 }
  decoded = CBOR.decode(payload)
  greeting = "hi"
  count = 5
RB
idx = index_with_core
doc = Struct.new(:ast, :text).new(Prism.parse(src), src)

# inferred-type hover at BOTH the assignment and a later use
check.("local hover at assignment (payload = {…})", title(doc, idx, 0, "payload"), "Hash")
check.("local hover at use (CBOR.decode(payload))", title(doc, idx, 1, "payload"), "Hash")
check.("string-assigned local",  title(doc, idx, 2, "greeting"), "String")
check.("integer-assigned local", title(doc, idx, 3, "count"),    "Integer")

# unknown RHS type (a call with no known return type) -> no hover, no crash
check.("unknown-typed local -> no hover",
       MrubyLsp::Hover.response(doc, { line: 1, character: src.lines[1].index("decoded") + 1 }, idx),
       nil)

# the inferred type's definition link is present (where the class lives)
v = MrubyLsp::Hover.response(doc, { line: 0, character: 2 }, idx)&.dig(:contents, :value)
check.("local hover links to the type's source", v.to_s.include?("hash.rb"), true)

# annotated parameter: hover shows the annotated class
psrc = <<~RB
  #: (String) -> Integer
  def parse(text)
    text
  end
RB
pidx = index_with_core
pdoc = Struct.new(:ast, :text).new(Prism.parse(psrc), psrc)
# hover `text` in the body (line 2)
check.("annotated param hover", title(pdoc, pidx, 2, "text"), "String")

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
