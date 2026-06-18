$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "mruby_lsp/locator"
require "mruby_lsp/index"
require "mruby_lsp/buffer_harvester"
include MrubyLsp
E = MrubyLsp::Index::Entry

def vm_method(idx, owner, m, singleton: false, private: false)
  e = E.new(name: "#{owner}#{singleton ? '.' : '#'}#{m}", owner: owner, kind: :method,
            uri: "mruby-core://#{owner}", line: 1, params: "()", native: true,
            singleton: singleton, doc: nil)
  private ? idx.add_private(e) : idx.add(e)
end

fails = 0
def names(entries) = entries.reject(&:singleton).map { |e| e.name.split(/[#.]/).last }.sort.uniq
check = lambda do |label, got, want|
  ok = got == want; fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def harvest(idx, uri, src, order)
  idx.set_buffer(uri, BufferHarvester.harvest(uri, Prism.parse(src).value, src), order)
end

# ===== 1. full dynamic surface on a buffer-only class =====
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
src1 = <<~RB
  class Foo
    def a; end
    def b; end
    private
    def c; end
    public
    def d; end
    private :a
    alias a2 d
    attr_accessor :x
    attr_reader :y
    define_method(:dm){ }
    undef_method :b
    def e; end
    remove_method :e
  end
RB
harvest(idx, "file:///f.rb", src1, 0)
check.("Foo public own methods", names(idx.methods_of("Foo")), %w[a2 d dm x x= y])
check.("Foo tombstones", idx.own_tombstones("Foo").to_a.sort, %w[b])
foo_priv = idx.private_methods_of("Foo").map { |e| e.name.split("#").last }
check.("Foo privates include a (retro) and c", (%w[a c] - foo_priv), [])
check.("Foo visible excludes b,c,e and private a", (names(idx.visible_methods("Foo")) & %w[a b c e]), [])
check.("Foo visible includes accessors+alias+define_method",
       (%w[a2 d dm x x= y] - names(idx.visible_methods("Foo"))), [])

# ===== 2. undef blocks an INHERITED method =====
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
idx.set_ancestors("Base", %w[Base Object Kernel BasicObject])
vm_method(idx, "Base", "inherited_m")
harvest(idx, "file:///s.rb", "class Sub < Base\n  undef_method :inherited_m\nend\n", 0)
check.("undef blocks inherited", names(idx.visible_methods("Sub")).include?("inherited_m"), false)

# ===== 3. remove_method on INHERITED does NOT block (reappears) =====
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
idx.set_ancestors("Base", %w[Base Object Kernel BasicObject])
vm_method(idx, "Base", "inherited_m")
harvest(idx, "file:///s2.rb", "class Sub2 < Base\n  remove_method :inherited_m\nend\n", 0)
check.("remove_method does NOT block inherited", names(idx.visible_methods("Sub2")).include?("inherited_m"), true)

# ===== 4. remove own copy -> parent reappears =====
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
idx.set_ancestors("Base", %w[Base Object Kernel BasicObject])
vm_method(idx, "Base", "inherited_m")
harvest(idx, "file:///s3.rb", "class Sub3 < Base\n  def inherited_m; end\n  remove_method :inherited_m\nend\n", 0)
check.("remove own copy, parent reappears", names(idx.visible_methods("Sub3")).include?("inherited_m"), true)
check.("  Sub3 own public table empty", names(idx.methods_of("Sub3")), [])

# ===== 5. def x; undef x; def x  nets to PRESENT =====
idx = MrubyLsp::Index.new
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
harvest(idx, "file:///r.rb", "class R\n  def x; end\n  undef_method :x\n  def x; end\nend\n", 0)
check.("def;undef;def nets present", names(idx.methods_of("R")), %w[x])
check.("  and no lingering tombstone", idx.own_tombstones("R").to_a, [])

# ===== 6. reopening a VM class: undef a compiled own method =====
idx = MrubyLsp::Index.new
idx.set_ancestors("String", %w[String Object Kernel BasicObject])
vm_method(idx, "String", "upcase"); vm_method(idx, "String", "downcase")
harvest(idx, "file:///str.rb", "class String\n  undef_method :upcase\nend\n", 0)
check.("buffer undef removes a compiled method", names(idx.visible_methods("String")).include?("upcase"), false)
check.("  sibling compiled method stays", names(idx.visible_methods("String")).include?("downcase"), true)

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
exit(fails.zero? ? 0 : 1)
