$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
%w[index locator completion hover definition].each { |f| require "mruby_lsp/#{f}" }
E = MrubyLsp::Entry

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

# A VM class reflects with only a synthetic uri (no source_location is recorded
# for the class itself). Its definition location is borrowed from its own
# #initialize — the cfunc that defines a C class — resolved like any native
# method (cfunc_offset -> addr2line). Stubbed resolver stands in for addr2line.
def index_with_stub
  idx = MrubyLsp::Index.new
  idx.native_resolver = Object.new.tap do |r|
    def r.resolve(off)
      { 100 => { uri: "file:///src/point.c", line: 88 },
        200 => { uri: "file:///src/widget.c", line: 12 } }[off]
    end
  end
  idx
end

def vm_class(idx, name)
  idx.add(E.new(name: name, owner: "Object", kind: :class, uri: "mruby-core://#{name}",
                line: nil, params: nil, native: false, singleton: false, doc: nil, superclass: "Object"))
end

idx = index_with_stub
vm_class(idx, "Point")
# initialize is PRIVATE -> reflector stores it via add_private; it's a cfunc.
idx.add_private(E.new(name: "Point#initialize", owner: "Point", kind: :method, uri: "mruby-core://Point",
                      line: nil, params: "(x, y)", native: true, singleton: false, doc: nil, cfunc_offset: 100))

c = idx.enrich(idx.resolve("Point").first)
check.("class uri borrowed from #initialize",  c.uri,  "file:///src/point.c")
check.("class line borrowed from #initialize", c.line, 88)

# end-to-end hover + F12 on a reference to the class
doc = Struct.new(:ast, :text).new(Prism.parse("y = Point\n"), "y = Point\n")
pos = { line: 0, character: 4 }
hv = MrubyLsp::Hover.response(doc, pos, idx)
df = MrubyLsp::Definition.locations(doc, pos, idx)
check.("hover links to the C source", hv.dig(:contents, :value).include?("point.c"), true)
check.("F12 navigates to the C source", df && df.size == 1 && df[0][:targetUri], "file:///src/point.c")

# no own initialize -> NO borrowed location (a monkey-patched own method must
# NOT stand in: e.g. Integer#to_json from a json gem would point Integer there).
idx2 = index_with_stub
vm_class(idx2, "Integer")
# a gem monkey-patches Integer#to_json (own by owner, but lives in the json gem)
idx2.add(E.new(name: "Integer#to_json", owner: "Integer", kind: :method, uri: "mruby-core://Integer",
               line: nil, params: "()", native: true, singleton: false, doc: nil,
               cfunc_offset: 200, from_gem: true))
w = idx2.enrich(idx2.resolve("Integer").first)
check.("no #initialize -> stays synthetic (not the gem method)", w.uri, "mruby-core://Integer")

# degraded (no resolver / unresolvable) -> stays synthetic, no crash, no link
idx3 = MrubyLsp::Index.new
vm_class(idx3, "Opaque")
check.("no resolver -> synthetic kept", idx3.enrich(idx3.resolve("Opaque").first).uri, "mruby-core://Opaque")
check.("synthetic class -> no F12 target",
       MrubyLsp::Definition.locations(Struct.new(:ast, :text).new(Prism.parse("z = Opaque\n"), "z = Opaque\n"),
                                      { line: 0, character: 4 }, idx3),
       [])

# a Ruby/mrblib class already has a file uri -> untouched (no borrowing)
idx4 = index_with_stub
idx4.add(E.new(name: "RubyCls", owner: "Object", kind: :class, uri: "file:///lib/ruby_cls.rb",
               line: 3, params: nil, native: false, singleton: false, doc: nil, superclass: "Object"))
rc = idx4.enrich(idx4.resolve("RubyCls").first)
check.("file-uri class left untouched", [rc.uri, rc.line], ["file:///lib/ruby_cls.rb", 3])

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
