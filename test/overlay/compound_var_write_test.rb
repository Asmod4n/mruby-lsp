$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
%w[index locator completion type_inference buffer_harvester scope_resolver hover definition].each { |f| require "mruby_lsp/#{f}" }

# Compound assignment FORMS define a variable just like `=`: `@x ||= 0` (the
# ubiquitous memoization idiom), `@@n &&= v`, `@x += 1`, `$g ||= …`. The buffer
# harvester used to record only plain Write/Target nodes, so a memoized ivar was
# invisible to completion/hover/ivar-schema. Editor-only: such code may never be
# compiled into the VM.

fails = 0
check = lambda do |label, ok, detail = nil|
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        #{detail}" if !ok && detail
end

SRC = <<~RB
  class Foo
    def n
      @count ||= 0
      @cache ||= {}
      @total += 1
      @flag &&= true
      @@registry ||= []
      $log ||= "x"
    end
  end
RB

doc = Struct.new(:ast, :text).new(Prism.parse(SRC), SRC)
entries = MrubyLsp::BufferHarvester.harvest("file:///t.rb", Prism.parse(SRC).value, SRC)
by = ->(kind) { entries.select { |e| e.kind == kind }.map(&:name).sort }

check.("||= / += / &&= ivars are harvested", by.call(:ivar) == %w[@cache @count @flag @total], by.call(:ivar).inspect)
check.("||= cvar is harvested", by.call(:cvar) == %w[@@registry], by.call(:cvar).inspect)
check.("||= gvar is harvested", by.call(:gvar) == %w[$log], by.call(:gvar).inspect)

# `@cache ||= {}` is as good a type source as `@cache = {}`.
off = SRC.length - 5
check.("@cache ||= {} infers Hash", MrubyLsp::TypeInference.infer_variable(:ivar, "@cache", off, doc, nil) == "Hash")
check.("@count ||= 0 infers Integer", MrubyLsp::TypeInference.infer_variable(:ivar, "@count", off, doc, nil) == "Integer")

# hover over a memoized ivar resolves (does not fall through to nil).
hpos = nil
SRC.each_line.with_index { |l, i| hpos = { line: i, character: (l.index("@cache") + 2) } if l.include?("@cache ||=") }
# @cache's inferred type is Hash; hover should produce contents, not nil.
idx = MrubyLsp::Index.new
%w[Hash Integer].each { |n| idx.add(MrubyLsp::Entry.new(name: n, owner: "Object", kind: :class, uri: "file:///c/#{n}.rb", line: 1, params: nil, native: false, singleton: false, doc: nil, superclass: "Object")) }
entries.each { |e| idx.add(e) }
hv = MrubyLsp::Hover.response(doc, hpos, idx)
check.("hover over @cache produces a result", !hv.nil?, hv.inspect)

# go-to-definition must resolve the TARGET of an op-assign ivar (`@x ||= 0`),
# not just a plain `@x = …`. (ruby-lsp parity: this was the one regression the
# char-by-char comparison surfaced — definition was empty on the OrWriteNode
# target while hover already worked.)
dsrc = "class Animal\n  def legs\n    @legs ||= 0\n  end\nend\n"
ddoc = Struct.new(:ast, :text).new(Prism.parse(dsrc), dsrc)
didx = MrubyLsp::Index.new
MrubyLsp::BufferHarvester.harvest("file:///d.rb", Prism.parse(dsrc).value, dsrc).each { |e| didx.add(e) }
dloc = MrubyLsp::Definition.locations(ddoc, { line: 2, character: 5 }, didx)
check.("F12 on @legs ||= resolves (not empty)", dloc && !dloc.empty?, dloc.inspect)

puts
puts(fails.zero? ? "ALL PASS" : "#{fails} FAILED")
exit(fails.zero? ? 0 : 1)
