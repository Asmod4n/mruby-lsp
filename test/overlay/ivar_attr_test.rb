$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "prism"
require "mruby_lsp/locator" # harvester uses Locator.code_units_encoding for ranges
require "mruby_lsp/buffer_harvester"
require "mruby_lsp/index"

BH  = MrubyLsp::BufferHarvester
fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

SRC = <<~RB
  class Conn
    native_ext_type :@sock, Socket
    attr_reader :sock
    attr_accessor :pair
    native_ext_type :@u, Integer, String
    attr_reader :u
  end
RB

def harvest(src, idx = nil)
  BH.harvest("file:///t.rb", Prism.parse(src).value, src, idx)
end
def ret(entries, name)
  e = entries.find { |x| x.name == name && x.kind == :method }
  e && e.return_type
end

# ── Part B: attr_* accessors inherit the ivar's declared type ──────────────
ent = harvest(SRC)
check.call("attr_reader inherits single-type decl",       ret(ent, "Conn#sock"), "Socket")
check.call("attr_accessor reader: no decl, no idx -> nil", ret(ent, "Conn#pair"), nil)
check.call("attr_accessor writer present (pair=)",         ent.any? { |e| e.name == "Conn#pair=" }, true)
check.call("attr_reader over UNION decl -> nil (no guess)", ret(ent, "Conn#u"), nil)

# writer of a typed ivar carries the type too (x = v evaluates to v : T)
SRC2 = "class C\n  native_ext_type :@h, Hash\n  attr_accessor :h\nend\n"
e2 = harvest(SRC2)
check.call("attr_accessor reader typed",  ret(e2, "C#h"),  "Hash")
check.call("attr_accessor writer typed",  ret(e2, "C#h="), "Hash")

# VM fallback: no buffer decl, but the index's VM schema has the ivar.
class StubIdx
  def initialize(map) = @map = map
  def ivar_type(cls, iv) = @map[[cls, iv.to_s]]
end
SRC3 = "class D\n  attr_reader :conn\nend\n"
e3 = harvest(SRC3, StubIdx.new({ ["D", "@conn"] => "Socket" }))
check.call("attr_reader falls back to VM index ivar_type", ret(e3, "D#conn"), "Socket")

# ── Part A: buffer native_ext_type feeds the index ivar layer (buffer-wins) ─
idx = MrubyLsp::Index.new
idx.set_buffer_ivar_schema("file:///t.rb", BH.ivar_schemas(Prism.parse(SRC).value))
check.call("index.ivar_type from buffer decl",  idx.ivar_type("Conn", "@sock"), "Socket")
check.call("index.ivar_type buffer union -> nil", idx.ivar_type("Conn", "@u"), nil)

idx.set_ivar_schema("Conn", { "@sock" => ["String"] })  # VM says String...
check.call("buffer decl WINS over VM schema",   idx.ivar_type("Conn", "@sock"), "Socket")

idx.clear_buffer("file:///t.rb")
check.call("after clear_buffer, VM schema shows", idx.ivar_type("Conn", "@sock"), "String")

puts(fail_count.zero? ? "\nALL PASS" : "\n#{fail_count} FAILED")
exit(fail_count.zero? ? 0 : 1)
