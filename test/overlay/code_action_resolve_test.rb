$LOAD_PATH.unshift File.expand_path("../../lib", __dir__), ENV.fetch("PRISM_LIB", "/tmp/prism-src/lib")
require "prism"
require "mruby_lsp/document_store"
require "mruby_lsp/code_action"
require "mruby_lsp/code_action_resolve"
include MrubyLsp

# codeAction/resolve model tests, prism-only (the byte-exact check against the
# 27 vendored ruby-lsp vectors lives in test/conformance/replay_actions.py and
# runs with the nightly VM build; this covers the same logic without a server).

fails = 0
check = lambda do |label, got, want|
  ok = got == want; fails += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  puts "        got:  #{got.inspect}\n        want: #{want.inspect}" unless ok
end

URI_ = "file:///t.rb"
D = ->(src) { Document.new(URI_, src) }
ACT = lambda do |title, kind, range|
  { title: title, kind: kind, data: { range: range, uri: URI_ } }
end
R = ->(sl, sc, el, ec) { { start: { line: sl, character: sc }, end: { line: el, character: ec } } }
edits = ->(res) { res.dig(:edit, :documentChanges, 0, :edits) }

# ── Extract Variable: replace selection, insert assignment above ─────────────
doc = D.(%(def foo\n  a = 1\n  b = 2\n  c = a + b\nend\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::EXTRACT_VARIABLE, "refactor.extract", R.(3, 6, 3, 11)))
check.("extract variable: two edits", edits.(res)&.size, 2)
check.("  selection becomes new_variable", edits.(res)[0], { range: R.(3, 6, 3, 11), newText: "new_variable" })
check.("  assignment inserted with indent", edits.(res)[1], { range: R.(3, 2, 3, 2), newText: "new_variable = a + b\n  " })

# one-line block: extraction goes INSIDE, semicolon-separated
doc = D.(%([1].each { |i| i + 1 }\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::EXTRACT_VARIABLE, "refactor.extract", R.(0, 15, 0, 20)))
check.("extract variable in one-line block", edits.(res)[1][:newText], " new_variable = i + 1;")

# ── Extract Method: def after the enclosing method / above at script level ──
doc = D.(%(def foo\n  answer = 42\nend\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::EXTRACT_METHOD, "refactor.extract", R.(1, 2, 1, 13)))
check.("extract method: def appended after end", edits.(res)[0][:newText], "\n\ndef new_method\n  answer = 42\nend")
check.("  call replaces selection", edits.(res)[1], { range: R.(1, 2, 1, 13), newText: "new_method" })

doc = D.(%(a = 5 + 2\na * 10\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::EXTRACT_METHOD, "refactor.extract", R.(0, 0, 1, 6)))
check.("extract method at script level", edits.(res)[0][:newText], "def new_method\n  a = 5 + 2\n  a * 10\nend\n\n")

# ── Toggle block style: braces <-> do/end, cursor and selection forms ───────
doc = D.(%(list.each { |a| a + 1 }\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::TOGGLE_BLOCK, "refactor.rewrite", R.(0, 12, 0, 12)))
check.("toggle braces -> do/end at cursor", edits.(res)[0][:newText], "do |a|\n  a + 1\nend")

doc = D.(%(list.each do |a|\n  a + 1\nend\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::TOGGLE_BLOCK, "refactor.rewrite", R.(0, 0, 2, 3)))
check.("toggle do/end -> braces on selection", edits.(res)[0][:newText], "{ |a| a + 1 }")

# ── Create Attribute Accessor family ─────────────────────────────────────────
doc = D.(%(class Foo\n  def initialize\n    @foo = 1\n  end\nend\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::CREATE_ATTR_READER, "", R.(2, 4, 2, 8)))
check.("attr_reader inserted at class body top", edits.(res)[0], { range: R.(1, 0, 1, 0), newText: "  attr_reader :foo\n\n" })

doc = D.(%(@foo = 1\n))
res = CodeActionResolve.response(doc, ACT.(CodeAction::CREATE_ATTR_ACCESSOR, "", R.(0, 1, 0, 1)))
check.("class-less accessor falls back to Program scope", edits.(res)[0][:newText], "  attr_accessor :foo\n\n")

# ── unresolvable inputs return the action UNCHANGED (edit-less no-op) ────────
doc = D.(%(a = 1\n))
act = ACT.(CodeAction::EXTRACT_VARIABLE, "refactor.extract", R.(0, 2, 0, 2))
check.("empty selection -> action unchanged", CodeActionResolve.response(doc, act), act)
act = ACT.(CodeAction::TOGGLE_BLOCK, "refactor.rewrite", R.(0, 2, 0, 2))
check.("cursor outside any block -> action unchanged", CodeActionResolve.response(doc, act), act)
act = ACT.(CodeAction::CREATE_ATTR_WRITER, "", R.(0, 0, 0, 5))
check.("no ivar in selection -> action unchanged", CodeActionResolve.response(doc, act), act)
check.("missing document -> action unchanged", CodeActionResolve.response(nil, act), act)

# ── the offer side pairs with resolve ────────────────────────────────────────
doc = D.(%(list.each { |a| @x = a }\n))
offers = CodeAction.response(doc, R.(0, 12, 0, 12), { diagnostics: [] }, URI_).map { |a| a[:title] }
check.("cursor in block offers toggle only", offers, [CodeAction::TOGGLE_BLOCK])
offers = CodeAction.response(doc, R.(0, 16, 0, 20), { diagnostics: [] }, URI_).map { |a| a[:title] }
check.("ivar selection offers extract + toggle + attr family",
       offers,
       [CodeAction::EXTRACT_VARIABLE, CodeAction::EXTRACT_METHOD, CodeAction::TOGGLE_BLOCK,
        CodeAction::CREATE_ATTR_READER, CodeAction::CREATE_ATTR_WRITER, CodeAction::CREATE_ATTR_ACCESSOR])

puts "\n#{fails.zero? ? 'ALL PASS' : "#{fails} FAILED"}"
exit(fails.zero? ? 0 : 1)
