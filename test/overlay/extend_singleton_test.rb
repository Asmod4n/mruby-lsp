$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"; require "mruby_lsp/locator"; require "mruby_lsp/index"; require "mruby_lsp/buffer_harvester"
include MrubyLsp
fails = 0
def names(es) = es.map { |e| e.name.split(/[#.]/).last }.sort.uniq
ck = lambda { |l,g,w| ok=(g==w); fails+=1 unless ok; puts "#{ok ? 'PASS':'FAIL'}  #{l}"; (puts "   got #{g.inspect} want #{w.inspect}" unless ok) }
def harvest(idx,uri,src,o) idx.set_buffer(uri, BufferHarvester.harvest(uri, Prism.parse(src).value, src), o) end

idx = MrubyLsp::Index.new
%w[Class Module Object Kernel].each { |k| idx.set_ancestors(k, [k]) }
harvest(idx, "file:///x.rb", <<~RB, 0)
  module Helper
    def help_me; end
  end
  class Foo
    def self.own_cm; end
    def inst; end
    extend Helper
  end
  module Util
    extend self
    def do_it; end
  end
RB
foo = names(idx.singleton_methods_for("Foo"))
ck.("Foo class methods include own def self.x", foo.include?("own_cm"), true)
ck.("Foo class methods include extended Helper#help_me", foo.include?("help_me"), true)
ck.("Foo class methods EXCLUDE instance method inst", foo.include?("inst"), false)
util = names(idx.singleton_methods_for("Util"))
ck.("extend self exposes do_it as class method", util.include?("do_it"), true)

# buffer superclass chain inherits class methods
idx2 = MrubyLsp::Index.new
%w[Class Module Object Kernel].each { |k| idx2.set_ancestors(k, [k]) }
harvest(idx2, "file:///y.rb", "class P\n  def self.pcm; end\nend\nclass C < P\n  def self.ccm; end\nend\n", 0)
cm = names(idx2.singleton_methods_for("C"))
ck.("subclass inherits parent class method (buffer chain)", (%w[ccm pcm] - cm), [])

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"; exit(fails.zero? ? 0 : 1)
