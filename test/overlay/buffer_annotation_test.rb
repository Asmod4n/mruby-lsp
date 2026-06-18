$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
# Full server-like chain: buffer harvesting drives return-type inference, which
# (for a param used as a receiver) falls back to the inline-annotation lookup.
# That lookup reads document.ast.comments -- the bug was that the harvester's
# lightweight tdoc.ast only carried .value, so opening ANY file with a method
# whose body calls a method on one of its params crashed with
#   NoMethodError: undefined method 'comments' for #<struct value=...>
%w[locator index inline_type type_inference completion scope_resolver buffer_harvester].each do |r|
  require "mruby_lsp/#{r}"
end
include MrubyLsp

fails = 0
check = lambda do |label, got, want|
  ok = got == want
  fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def harvest_ok(src)
  ops = BufferHarvester.harvest("file:///t.rb", Prism.parse(src).value, src, nil)
  [true, ops]
rescue => e
  puts "        raised: #{e.class}: #{e.message[0, 70]}"
  [false, nil]
end

# ── param used as a receiver, with a plain comment above (mirrors the CBOR
#    file: `def self.diag(buf, pos); buf.getbyte(pos); ...`). Pre-fix crash. ──
ok, ops = harvest_ok("module M\n  # a doc comment, like the real file\n  def self.f(s)\n    s.bytesize\n  end\nend\n")
check.("commented param-as-receiver def does not crash", ok, true)
check.("  and still emits f", (ops || []).any? { |e| e.name.end_with?("f") }, true)

# ── same, but with a real #: annotation above (the marker InlineType reads). ──
ok2, ops2 = harvest_ok("module M\n  #: (String) -> Integer\n  def self.g(s)\n    s.bytesize\n  end\nend\n")
check.("annotated param-as-receiver def does not crash", ok2, true)
check.("  and still emits g", (ops2 || []).any? { |e| e.name.end_with?("g") }, true)

# ── no comment at all: the comments lookup must also cope with an empty set. ──
ok3, = harvest_ok("module M\n  def self.h(s)\n    s.bytesize\n  end\nend\n")
check.("param-as-receiver def with no comments does not crash", ok3, true)

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
exit(fails.zero? ? 0 : 1)
