$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"; require "mruby_lsp/locator"; require "mruby_lsp/index"; require "mruby_lsp/buffer_harvester"
include MrubyLsp; f=0
ck=lambda{|l,g,w| ok=(g==w); f+=1 unless ok; puts "#{ok ? 'PASS':'FAIL'}  #{l}"; (puts "  got #{g.inspect} want #{w.inspect}" unless ok)}
idx=MrubyLsp::Index.new
# VM: Base is a class with a class method; Comparable is a module (no BasicObject)
idx.set_ancestors("Base", %w[Base Object Kernel BasicObject])
idx.set_ancestors("Comparable", %w[Comparable])
idx.set_ancestors("Object", %w[Object Kernel BasicObject])
%w[Class Module Object Kernel].each{|k| idx.set_ancestors(k,[k]) unless idx.ancestors(k)!=[k] rescue nil}
ck.("vm_class? Base (class)", idx.vm_class?("Base"), true)
ck.("vm_class? Comparable (module)", idx.vm_class?("Comparable"), false)
# Base has a VM class method; buffer Sub < Base should inherit it
base_cm = MrubyLsp::Index::Entry.new(name:"Base.factory", owner:"Base", kind: :method, uri:"x", line:1, params:"()", native:true, singleton:true, doc:nil)
idx.add(base_cm)
idx.set_buffer("file:///s.rb", BufferHarvester.harvest("file:///s.rb", Prism.parse("class Sub < Base\n  def self.own; end\nend\n").value, "class Sub < Base\n  def self.own; end\nend\n"), 0)
cms = idx.singleton_methods_for("Sub").map{|e| e.name.split(/[.#]/).last}
ck.("Sub inherits Base's VM class method 'factory'", cms.include?("factory"), true)
ck.("Sub has own class method 'own'", cms.include?("own"), true)
puts "\n#{f.zero? ? 'ALL PASS' : "#{f} FAILED"}"; exit(f.zero? ? 0 : 1)
