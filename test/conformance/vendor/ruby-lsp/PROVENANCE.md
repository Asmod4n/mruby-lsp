# Vendored ruby-lsp conformance vectors

These are ruby-lsp's own expectation tests, copied verbatim. They are our ONLY
source of truth for conformance — the suite asserts against ruby-lsp's own
definition of correct, not hand-picked cases. Replaying them must not depend on
a network clone; that is why they live in the tree.

## Pin
- upstream:  https://github.com/Shopify/ruby-lsp
- version:   0.26.9   (VERSION file at the pinned commit)
- commit:    88c3583f7944358975041f92ad9330154b042cf9
- date:      2026-06-09
- vendored:  2026-06-12

To refresh: re-clone at a new commit, re-copy `test/expectations` +
`test/fixtures` + `LICENSE.txt` here, bump this pin, and RE-SCORE every feature
(vectors drift — e.g. document_symbol went 13 -> 14 vectors since the first
scoring run; a refresh can silently move the green set).

## What's here
- `test/expectations/<feature>/<name>.exp.json` — request `params` + the exact
  expected `result`, per feature (207 vectors).
- `test/fixtures/<name>.rb` — the source each expectation runs against (189).
- `LICENSE.txt` — ruby-lsp is MIT (Copyright Shopify Inc.). Retained for
  attribution; these files remain under ruby-lsp's license, not ours.

## How we compare (READ THIS — it is not byte-equality everywhere)
Our output legitimately differs from ruby-lsp's on two axes, BY DESIGN:

1. SORT. We order results by our own usefulness rule (literal scope distance),
   not ruby-lsp's order. Any feature whose result is an ORDERED list that we
   re-sort cannot be byte-compared — it must be compared as a SET on content,
   with our documented sort verified separately. (Completion is the clearest
   case.)
2. CONTENT. Our source of truth is the live mruby VM; ruby-lsp's is CRuby + RBS.
   Symbols/types unique to one runtime differ correctly. Comparison is over the
   SHARED subset only; runtime-unique entries are ignored, never failed.

Byte-equality is valid ONLY where we already emit ruby-lsp's document order and
the content is language-structural (not runtime-specific): selection_ranges,
folding_ranges, document_highlight, document_symbol. Those are scored byte-equal
today and pass. Everything else needs the semantic comparator (shared-subset +
sort-aware) before it can be scored at all.

The C bridge is not involved in any of this. It is a dumb reflection conduit;
all comparison/sort/structure is host Ruby + this harness.
