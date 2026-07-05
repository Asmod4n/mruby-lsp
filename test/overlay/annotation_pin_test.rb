$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "tmpdir"
require "mruby_lsp/index"
require "mruby_lsp/completion"
include MrubyLsp
E = MrubyLsp::Index::Entry

# The three ways a hand-written type reaches inference when the AST can't
# prove one (a factory like URL() dispatches per scheme — statically unknowable,
# and eval is banned):
#   A. rescue bindings: `rescue Foo => e` — the clause IS the type test.
#   B. Kernel conversion casts: Array(x)/String(x)/… — language-defined.
#   C. trailing local pin: `x = factory() #: Foo` (steep-style).
#   D. `#:` on a COMPILED method's def, read from its source file (Stage 2.5),
#      so a gem annotates once and every consumer's chains type.

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

ti = MrubyLsp::TypeInference
def D(s) = Struct.new(:ast, :text).new(Prism.parse(s), s)
at = ->(d, name, needle = nil) { MrubyLsp::TypeInference.infer_local(name.to_sym, d.text.rindex(needle || name.to_s), d) }

# ── A. rescue bindings ────────────────────────────────────────────────────────
d = D(%(begin\n  work\nrescue KeyError => e\n  e\nend\n))
check.("rescue KeyError => e      -> KeyError",      at.(d, :e, "e\nend"), "KeyError")
d = D(%(begin\n  work\nrescue URL::SchemeError => e\n  e\nend\n))
check.("rescue A::B => e          -> A::B",          at.(d, :e, "e\nend"), "URL::SchemeError")
d = D(%(begin\n  work\nrescue => e\n  e\nend\n))
check.("bare rescue => e          -> StandardError", at.(d, :e, "e\nend"), "StandardError")
d = D(%(begin\n  work\nrescue KeyError, TypeError => e\n  e\nend\n))
check.("mixed rescue list         -> union",         at.(d, :e, "e\nend"), "KeyError | TypeError")
d = D(%(begin\n  work\nrescue KeyError, KeyError => e\n  e\nend\n))
check.("uniform rescue list       -> the class",     at.(d, :e, "e\nend"), "KeyError")

# ── B. Kernel conversion casts ────────────────────────────────────────────────
%w[Array String Integer Float Hash Rational Complex].each do |k|
  d = D(%(v = #{k}(raw)\nv\n))
  check.("#{k}(x)#{' ' * (8 - k.length)}          -> #{k}", at.(d, :v, "v\n"), k)
end
# a bare constant read is NOT the conversion
d = D(%(v = Integer\nv\n))
check.("bare Integer constant     -> nil (class, not cast)", at.(d, :v, "v\n"), nil)
# Stage 1: a buffer redefinition of the conversion wins
d = D(%(def Array(x); "s"; end\nv = Array(raw)\nv\n))
check.("buffer def Array() wins   -> String",        at.(d, :v, "v\n"), "String")

# ── C. trailing local pin ─────────────────────────────────────────────────────
d = D(%(api = URL("https://x") #: URL::HTTP\napi\n))
check.("x = f() #: URL::HTTP      -> URL::HTTP",     at.(d, :api, "api\n"), "URL::HTTP")
d = D(%(api = URL("https://x") #: not a type\napi\n))
check.("non-constant pin          -> nil",           at.(d, :api, "api\n"), nil)
d = D(%(api = "s" #: SomeClass\napi\n))
check.("pin WINS over inference   -> SomeClass",     at.(d, :api, "api\n"), "SomeClass")
d = D(%(api = URL("x") #: A | B\napi\n))
check.("union pin                 -> union",         at.(d, :api, "api\n"), "A | B")
d = D(%(api = URL("x") #: A | not a type\napi\n))
check.("union pin w/ bad segment  -> nil",           at.(d, :api, "api\n"), nil)

# ── D. `#:` on a compiled method, read from its source (Stage 2.5) ───────────
def m(owner, name, uri:, line:, rt: nil, singleton: false)
  sep = singleton ? "." : "#"
  E.new(name: "#{owner}#{sep}#{name}", owner: owner, kind: :method, uri: uri,
        line: line, params: "()", native: false, singleton: singleton, doc: nil,
        return_type: rt)
end
def cls(name, uri)
  E.new(name: name, owner: "Object", kind: :class, uri: uri, line: 1,
        params: nil, native: false, singleton: false, doc: nil, superclass: "Object")
end

Dir.mktmpdir do |dir|
  src = File.join(dir, "endpoints.rb")
  File.write(src, <<~RB)
    module URL
      class HTTP
        #: (**untyped) -> URL::Response
        def get(**o)
          URL._fire(:GET, @uri, nil, o)
        end
      end
    end
  RB
  uri = "file://#{src}"
  idx = MrubyLsp::Index.new
  %w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, c == "Object" ? %w[Object Kernel BasicObject] : [c]) }
  idx.set_ancestors("URL::HTTP", %w[URL::HTTP Object Kernel BasicObject])
  entry = m("URL::HTTP", "get", uri: uri, line: 4) # the def line the VM recorded
  idx.set_buffer("file:///vm.rb", [cls("URL::HTTP", uri), entry], 0)

  check.("VM `#:` read from source file", idx.ruby_return_annotation(entry), "URL::Response")

  # end to end: a local assigned from the annotated VM method types
  d = D(%(ep = URL::HTTP.new("x")\nresp = ep.get\nresp\n))
  # ep's class comes from .new; get resolves on URL::HTTP; its VM annotation
  # supplies the return type even though endpoints.rb is NOT open.
  check.("chain through VM annotation -> URL::Response",
         ti.infer_local(:resp, d.text.rindex("resp\n"), d, idx), "URL::Response")

  # drifted file: annotation still found via find_def by name
  entry2 = m("URL::HTTP", "get", uri: uri, line: 99)
  check.("stale recorded line still resolves", idx.send(:compute_ruby_return_annotation, entry2, uri), "URL::Response")
end

puts "\n#{fail_count.zero? ? 'ALL PASS' : "#{fail_count} FAILED"}"
exit(fail_count.zero? ? 0 : 1)
