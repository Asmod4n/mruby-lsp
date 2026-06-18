$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
%w[index locator completion type_inference buffer_harvester hover definition scope_resolver].each { |f| require "mruby_lsp/#{f}" }
include MrubyLsp

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def build(src)
  uri = "file:///test.rb"
  ast = Prism.parse(src)
  idx = MrubyLsp::Index.new
  idx.set_buffer(uri, MrubyLsp::BufferHarvester.harvest(uri, ast.value, src, idx), [0, uri])
  [idx, Struct.new(:ast, :text).new(ast, src)]
end

def hover_title(doc, idx, line, col)
  v = MrubyLsp::Hover.response(doc, { line: line, character: col }, idx)&.dig(:contents, :value)
  v && v.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("```") }.first
end

# ── a class defined inside a call block (assert do … end) is harvested ───────
src = <<~RB
  assert('registered tag') do
    class RegStrict
      native_ext_type :@v, Integer
      def initialize(v); @v = v; end
      def _before_encode; raise "forbidden"; end
    end
    CBOR.register_tag(1005, RegStrict)
  end
RB
idx, doc = build(src)
names = idx.symbol_entries.map(&:name)
check.("class-in-block harvested",          names.include?("RegStrict"), true)
check.("method-in-block harvested",         names.include?("RegStrict#initialize"), true)
check.("second method-in-block harvested",  names.include?("RegStrict#_before_encode"), true)

# hover + F12 on RegStrict where it's USED (the register_tag line)
reg_line = 6
col = src.lines[reg_line].index("RegStrict") + 1
check.("hover RegStrict (used in block)", hover_title(doc, idx, reg_line, col), "RegStrict")
check.("F12 RegStrict (used in block)",
       MrubyLsp::Definition.locations(doc, { line: reg_line, character: col }, idx)&.size, 1)

# ── module + nested class in a block ─────────────────────────────────────────
src2 = <<~RB
  describe "x" do
    module Outer
      class Inner; def go; end; end
    end
  end
RB
idx2, = build(src2)
n2 = idx2.symbol_entries.map(&:name)
check.("module-in-block harvested",        n2.include?("Outer"), true)
check.("nested class-in-block harvested",  n2.include?("Outer::Inner"), true)
check.("nested method-in-block harvested", n2.include?("Outer::Inner#go"), true)

# ── class defined under a conditional still harvested ────────────────────────
idx3, = build("class Cond; end if RUBY_VERSION\n")
check.("class under modifier-if harvested", idx3.symbol_entries.map(&:name).include?("Cond"), true)

# ── Foo.new resolves to Foo#initialize (the constructor), not Class#new ──────
src4 = <<~RB
  class Widget
    def initialize(w, h); @w = w; @h = h; end
  end
  x = Widget.new(1, 2)
RB
idx4, doc4 = build(src4)
new_line = 3
ncol = src4.lines[new_line].index("new") + 1
check.(".new hover -> initialize signature", hover_title(doc4, idx4, new_line, ncol), "initialize(w, h)")
check.(".new F12 -> the def initialize",
       MrubyLsp::Definition.locations(doc4, { line: new_line, character: ncol }, idx4)&.size, 1)

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
