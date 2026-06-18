$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"; require "mruby_lsp/locator"; require "mruby_lsp/index"; require "mruby_lsp/buffer_harvester"
include MrubyLsp; f=0
ck=lambda{|l,g,w| ok=(g==w); f+=1 unless ok; puts "#{ok ? 'PASS':'FAIL'}  #{l}"; (puts "  got #{g.inspect} want #{w.inspect}" unless ok)}
def harvest(idx,uri,src,o) idx.set_buffer(uri, BufferHarvester.harvest(uri, Prism.parse(src).value, src), o) end
def names(es) = es.map{|e| e.name.split(/[#.]/).last}.sort.uniq

idx = MrubyLsp::Index.new
%w[Class Module Object Kernel].each{|k| idx.set_ancestors(k,[k])}
harvest(idx, "file:///s.rb", <<~RB, 0)
  class Foo
    class << self
      def sing_a; end
      attr_reader :conf
      alias sing_b sing_a
      private
      def hidden; end
    end
    def inst; end
  end
  class << Foo
    def sing_c; end
  end
RB
cms = names(idx.singleton_methods_for("Foo"))
ck.("class<<self def -> class method", cms.include?("sing_a"), true)
ck.("class<<self attr_reader -> class accessor", cms.include?("conf"), true)
ck.("class<<self alias -> class alias", cms.include?("sing_b"), true)
ck.("private inside class<<self hides", cms.include?("hidden"), false)
ck.("class << Foo (const target) def", cms.include?("sing_c"), true)
ck.("instance method NOT in class methods", cms.include?("inst"), false)
ck.("inst still an instance method", names(idx.visible_methods("Foo")).include?("inst"), true)
ck.("singletons NOT in instance methods", (names(idx.visible_methods("Foo")) & %w[sing_a sing_b sing_c conf]), [])

# singleton-side undef drops a class<<self method
idx2 = MrubyLsp::Index.new
%w[Class Module Object Kernel].each{|k| idx2.set_ancestors(k,[k])}
harvest(idx2, "file:///u.rb", "class Bar\n  def self.gone; end\n  class << self\n    undef_method :gone\n  end\nend\n", 0)
ck.("singleton-side undef drops class method", names(idx2.singleton_methods_for("Bar")).include?("gone"), false)

puts "\n#{f.zero? ? 'ALL PASS' : "#{f} FAILED"}"; exit(f.zero? ? 0 : 1)
