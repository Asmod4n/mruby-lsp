$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "mruby_lsp/index"
require "mruby_lsp/completion"
require "mruby_lsp/union_type"
require "mruby_lsp/hover"
include MrubyLsp
E = MrubyLsp::Index::Entry

# Union types: a method whose every terminal is PROVEN keeps the whole set as
# one sorted "A | B" string instead of collapsing to unknown; a union stays a
# plain string so every existing type pipeline carries it unchanged; guards
# between a write and a use narrow it back to single classes. Any unknown
# alternative still poisons the whole type -- unions never contain guesses.

fail_count = 0
check = lambda do |label, got, want|
  ok = got == want
  fail_count += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

def doc(src) = Struct.new(:ast, :text).new(Prism.parse(src), src)
ti = MrubyLsp::TypeInference
ut = MrubyLsp::UnionType
at = ->(d, name, needle) { ti.infer_local(name.to_sym, d.text.rindex(needle), d) }

# ── A. the UnionType helpers ──────────────────────────────────────────────────

check.("of one name -> bare (fast path)   ", ut.of(["String"]), "String")
check.("of sorts + dedups                 ", ut.of(%w[B A B]), "A | B")
check.("of flattens nested unions         ", ut.of(["B | C", "A"]), "A | B | C")
check.("of nil member -> nil (no guesses) ", ut.of(["A", nil]), nil)
check.("of empty -> nil                   ", ut.of([]), nil)
check.("no width cap (8 members survive)  ", ut.of(%w[A B C D E F G H]),
       "A | B | C | D | E | F | G | H")
check.("members round-trips               ", ut.members("A | B"), %w[A B])
check.("union? on bare name -> false      ", ut.union?("String"), false)
check.("intersect picks the named member  ", ut.intersect("A | B", "B"), "B")
check.("intersect to nothing -> nil       ", ut.intersect("A | B", "C"), nil)
check.("subtract drops a member           ", ut.subtract("A | B | C", "B"), "A | C")
check.("subtract to one -> bare name      ", ut.subtract("A | B", "B"), "A")
check.("subtract all -> nil               ", ut.subtract("A", "A"), nil)

# ── B. producers: infer_return keeps proven sets ─────────────────────────────

def find_def(d, name)
  found = nil
  v = lambda { |n| (found = n if n.is_a?(Prism::DefNode) && n.name == name); n.compact_child_nodes.each(&v) }
  v.call(d.ast.value)
  found
end

d = doc(%(def fetch(flag)\n  return 1 if flag\n  "s"\nend\n))
check.("early return + terminal -> union  ", ti.infer_return(find_def(d, :fetch), d, nil, 0), "Integer | String")

d = doc(%(def fetch(flag)\n  if flag then 1 else "s" end\nend\n))
check.("if/else terminals -> union        ", ti.infer_return(find_def(d, :fetch), d, nil, 0), "Integer | String")

d = doc(%(def fetch(flag)\n  return 1 if flag\n  work\nend\n))
check.("any unknown terminal -> nil       ", ti.infer_return(find_def(d, :fetch), d, nil, 0), nil)

d = doc(%(#: (String) -> (Pq::Result | Pq::Result::Error)\ndef exec(sql)\n  raw\nend\n))
check.("#: union annotation wins          ", ti.infer_return(find_def(d, :exec), d, nil, 0),
       "Pq::Result | Pq::Result::Error")

# a union flows through a local like any other type
d = doc(%(def fetch(f)\n  return 1 if f\n  "s"\nend\nx = fetch(true)\nx\n))
check.("local <- union-returning call     ", at.(d, :x, "x\n"), "Integer | String")

# ── C. narrowing: guards between write and use ───────────────────────────────

SRC_RET = %(def fetch(f)\n  return 1 if f\n  "s"\nend\nx = fetch(true)\nreturn x if x.is_a?(String)\nx\n)
check.("early-return is_a? subtracts      ", at.(doc(SRC_RET), :x, "x\n"), "Integer")

d = doc(%(x = nil #: A | B\nif x.is_a?(A)\n  x\nend\n))
check.("then-branch intersects            ", at.(d, :x, "x\nend"), "A")

d = doc(%(x = nil #: A | B\nif x.is_a?(A)\n  work\nelse\n  x\nend\n))
check.("else-branch subtracts             ", at.(d, :x, "x\nend"), "B")

d = doc(%(x = nil #: A | B\nunless x.is_a?(A)\n  x\nend\n))
check.("unless then-branch subtracts      ", at.(d, :x, "x\nend"), "B")

d = doc(%(x = nil #: A | B\nraise Bad unless x.is_a?(A)\nx\n))
check.("raise-unless intersects after     ", at.(d, :x, "x\n"), "A")

d = doc(%(x = nil #: A | B | C\ncase x\nwhen A\n  x\nwhen B\n  x\nelse\n  x\nend\n))
check.("case/when branch intersects       ", at.(d, :x, "x\nwhen B"), "A")
check.("later when subtracts earlier      ", at.(d, :x, "x\nelse"), "B")
check.("case else subtracts all listed    ", at.(d, :x, "x\nend"), "C")

d = doc(%(x = nil #: A | B\ncase x\nin A\n  x\nend\n))
check.("case/in constant intersects       ", at.(d, :x, "x\nend"), "A")

d = doc(%(x = nil #: A | NilClass\nif x\n  x\nend\n))
check.("truthiness drops NilClass         ", at.(d, :x, "x\nend"), "A")

d = doc(%(x = nil #: A | B\nif x.is_a?(A)\n  x = other\n  x\nend\n))
check.("reassignment cancels narrowing    ", at.(d, :x, "x\nend"), nil)

d = doc(%(x = nil #: A | B\nif x.is_a?(C)\n  x\nend\n))
check.("guard outside union -> unnarrowed ", at.(d, :x, "x\nend"), "A | B")

d = doc(%(x = ""\nif x.is_a?(String)\n  x\nend\n))
check.("single type stays untouched       ", at.(d, :x, "x\nend"), "String")

# ── D. hover renders the union; guarded code hovers the single class ─────────

def hover_index
  idx = MrubyLsp::Index.new
  %w[Object Kernel BasicObject].each { |c| idx.set_ancestors(c, [c, "Object", "Kernel", "BasicObject"].uniq) }
  %w[String Integer].each do |n|
    idx.add(E.new(name: n, owner: "Object", kind: :class, uri: "file:///core/#{n.downcase}.rb",
                  line: 1, params: nil, native: false, singleton: false, doc: nil, superclass: "Object"))
  end
  idx
end

def hover_title(d, idx, line, needle)
  col = d.text.lines[line].index(needle) + 1
  v = MrubyLsp::Hover.response(d, { line: line, character: col }, idx)
  v && v.dig(:contents, :value).lines.reject { |l| l.strip.empty? || l.start_with?("```") }.first&.strip
end

HSRC = %(def fetch(f)\n  return 1 if f\n  "s"\nend\nx = fetch(true)\nx\nreturn x if x.is_a?(String)\nx\n)
hd = doc(HSRC)
hidx = hover_index
check.("hover before guard -> the union   ", hover_title(hd, hidx, 5, "x"), "Integer | String")
check.("hover after guard  -> narrowed    ", hover_title(hd, hidx, 7, "x"), "Integer")
v = MrubyLsp::Hover.response(hd, { line: 5, character: 1 }, hidx)&.dig(:contents, :value).to_s
check.("union hover links every member    ",
       v.include?("integer.rb") && v.include?("string.rb"), true)

# ── E. completion on a union receiver: the member intersection only ──────────

def mm(owner, name)
  E.new(name: "#{owner}##{name}", owner: owner, kind: :method, uri: "file:///vm.rb",
        line: 1, params: "()", native: false, singleton: false, doc: nil)
end

cidx = MrubyLsp::Index.new
%w[Object Kernel BasicObject].each { |c| cidx.set_ancestors(c, [c, "Object", "Kernel", "BasicObject"].uniq) }
cidx.set_ancestors("Result", %w[Result Object Kernel BasicObject])
cidx.set_ancestors("Failure", %w[Failure Object Kernel BasicObject])
cidx.set_buffer("file:///vm.rb", [
  mm("Result", "fields"), mm("Result", "ntuples"), mm("Result", "check"),
  mm("Failure", "message"), mm("Failure", "check"),
], 0)

def col(s)
  off = s.index("§"); src = s.sub("§", "")
  before = src[0...off]; line = before.count("\n"); chr = off - (before.rindex("\n") || -1) - 1
  [Struct.new(:ast, :text).new(Prism.parse(src), src), { line: line, character: chr }]
end

CSRC = %(def run(f)\n  return Result.new if f\n  Failure.new\nend\nx = run(true)\nx.§\n)
cd, cpos = col(CSRC)
labels = Completion.items(cd, cpos, cidx).map { |i| i[:label] }
check.("union completion offers shared     ", labels.include?("check"), true)
check.("union completion hides partials    ",
       labels.include?("ntuples") || labels.include?("message"), false)

# after the guard, the single member's full surface is back
GSRC = %(def run(f)\n  return Result.new if f\n  Failure.new\nend\nx = run(true)\nreturn x if x.is_a?(Failure)\nx.§\n)
gd, gpos = col(GSRC)
glabels = Completion.items(gd, gpos, cidx).map { |i| i[:label] }
check.("narrowed completion = full member  ", glabels.include?("ntuples") && glabels.include?("check"), true)
check.("narrowed hides other member        ", glabels.include?("message"), false)

# ── F. dispatch tables + compiled sources: URL() types with NO annotation ────
# Simulates the mruby-url shape as a COMPILED gem: Kernel#URL (private) whose
# recorded source calls URL.call, which indexes a constant hash of classes and
# news the result. The constant's VALUE facts come from the index (captured
# off the live VM at populate in production; hand-set here).

require "tmpdir"
FDIR = Dir.mktmpdir
FSRC = File.join(FDIR, "fakeurl.rb")
File.write(FSRC, <<~RB)
  class URL
    def self.call(uri)
      scheme = uri
      klass = SCHEME_CLIENTS[scheme]
      return klass.new(uri) if klass
      raise ArgumentError, "nope"
    end

    class HTTP
      def get(o = {})
        Response.new
      end
    end
  end

  module Kernel
    def URL(uri)
      URL.call(uri)
    end
  end
RB

fidx = MrubyLsp::Index.new
%w[Object Kernel BasicObject].each { |c| fidx.set_ancestors(c, [c, "Object", "Kernel", "BasicObject"].uniq) }
fidx.set_ancestors("URL",           %w[URL Object Kernel BasicObject])
fidx.set_ancestors("URL::HTTP",     %w[URL::HTTP Object Kernel BasicObject])
fidx.set_ancestors("URL::FTP",      %w[URL::FTP URL::Transfer Object Kernel BasicObject])
fidx.set_ancestors("URL::Response", %w[URL::Response Object Kernel BasicObject])
def fm(owner, name, uri:, line:, singleton: false)
  E.new(name: "#{owner}#{singleton ? '.' : '#'}#{name}", owner: owner, kind: :method,
        uri: uri, line: line, params: "()", native: false, singleton: singleton, doc: nil)
end
furi = "file://#{FSRC}"
%w[URL URL::HTTP URL::FTP URL::Transfer URL::Response].each do |c|
  fidx.add(E.new(name: c, owner: "Object", kind: :class, uri: "file:///vm.rb", line: 1,
                 params: nil, native: false, singleton: false, doc: nil, superclass: "Object"))
end
fidx.add(fm("URL", "call", uri: furi, line: 2, singleton: true))
fidx.add(fm("URL::HTTP", "get", uri: furi, line: 9))
fidx.add(fm("URL::HTTP", "post", uri: "file:///vm.rb", line: 1))
fidx.add(fm("URL::FTP", "download", uri: "file:///vm.rb", line: 1))
fidx.add(fm("URL::Response", "body", uri: "file:///vm.rb", line: 1))
fidx.add_private(fm("Kernel", "URL", uri: furi, line: 17))
fidx.set_const_value("URL::SCHEME_CLIENTS",
                     own: "Hash", is_class: false,
                     members: %w[URL::HTTP URL::FTP], members_are_classes: true)
fidx.set_const_value("URL::KNOWN",
                     own: "Array", is_class: false,
                     members: %w[String], members_are_classes: false)

def call_named(d, name)
  found = nil
  v = lambda { |n| (found = n if n.is_a?(Prism::CallNode) && n.name == name); n.compact_child_nodes.each(&v) }
  v.call(d.ast.value)
  found
end

fat = ->(d, name, needle) { ti.infer_local(name.to_sym, d.text.rindex(needle), d, fidx) }

d = doc(%(x = URL("https://x")\nx\n))
check.("URL() -> union, NO annotation     ", ti.infer_call(call_named(d, :URL), d, fidx), "URL::FTP | URL::HTTP")
check.("union flows into the local        ", fat.(d, :x, "x\n"), "URL::FTP | URL::HTTP")

# is_a? guard against the PARENT subtracts the subclass member (VM ancestry)
d = doc(%(x = URL("https://x")\nreturn x if x.is_a?(URL::Transfer)\nx\n))
check.("ancestry-aware narrowing          ", fat.(d, :x, "x\n"), "URL::HTTP")

# chained through a compiled method: Stage 2.6 infers get's body and QUALIFIES
# the as-written name through the def's nesting (Response -> URL::Response)
d = doc(%(y = URL::HTTP.new("https://x").get\ny\n))
check.("compiled-source chain -> Response ", fat.(d, :y, "y\n"), "URL::Response")

# compiled VALUE constant facts: the constant itself, and indexing it
d = doc(%(k = URL::KNOWN\nk\n))
check.("compiled const -> its value class ", fat.(d, :k, "k\n"), "Array")
d = doc(%(s = URL::KNOWN[0]\ns\n))
check.("compiled const[i] -> member union ", fat.(d, :s, "s\n"), "String")

# raise arms never poison a proven return
d = doc(%(def pick(f)\n  return 1 if f\n  raise "nope"\nend\n))
check.("raise arm contributes no type     ", ti.infer_return(find_def(d, :pick), d, nil, 0), "Integer")

puts fail_count.zero? ? "\nall green" : "\n#{fail_count} FAILED"
exit(fail_count.zero? ? 0 : 1)
