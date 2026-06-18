# Conformance via ruby-lsp's own expectation suite

ruby-lsp ships expectation tests: `test/fixtures/<name>.rb` paired with
`test/expectations/<feature>/<name>.exp.json`, where each `.exp.json` carries the
request `params` (position/args) AND the exact expected `result`. We replay those
against our server and diff — using ruby-lsp's own definition of correct, not
hand-picked cases.

## Vectors are VENDORED (the only source of truth we actually work against)
The vectors live in the tree at `vendor/ruby-lsp/` so the suite is reproducible
without a network clone. Pinned: ruby-lsp **0.26.9**, commit
`88c3583f7944358975041f92ad9330154b042cf9` (2026-06-09). See
`vendor/ruby-lsp/PROVENANCE.md` for refresh procedure + license (MIT, Shopify).

The three replay scripts default `RLSRC` to that vendored dir; set the `RLSRC`
env var to point at a different checkout if refreshing/comparing.

- `replay_positional.py <feature> <lspMethod>` — features whose params include a
  cursor position (document_highlight, etc.).
- `replay_document.py <feature> <lspMethod>` — whole-document features
  (documentSymbol, foldingRange, semanticTokens/full).
- `replay.py <feature> <lspMethod> <shape>` — shape is position|positions|document.

## How we compare — SEMANTIC, not byte-equal everywhere
Our output legitimately differs from ruby-lsp's on two axes, BY DESIGN:

1. SORT — we order by our own usefulness rule (literal scope distance), not
   ruby-lsp's order. A feature whose result is an ORDERED list we re-sort cannot
   be byte-compared; it must be compared as a SET on content, our sort verified
   separately. (Completion is the clearest case.)
2. CONTENT — our truth is the live mruby VM; ruby-lsp's is CRuby + RBS. Symbols
   and types unique to one runtime differ correctly; comparison is over the
   SHARED subset, runtime-unique entries ignored (never failed).

Byte-equality is valid ONLY where we already emit ruby-lsp's document order and
the content is language-structural (not runtime-specific). That is exactly the
four structural features scored below. Everything else needs the semantic
comparator (shared-subset + sort-aware) before it can be scored at all.

The C bridge is not involved: it is a dumb reflection conduit; all sort,
comparison, and structure is host Ruby + this harness.

## Scorecard (byte-equality, against the VENDORED vectors)
- selection_ranges:   35/35  GREEN
- folding_ranges:     48/48  GREEN  (statements-range vs simple-range, comment/import runs, def multiline split; document order)
- document_highlight: 16/16  GREEN  (identifier match + structural keyword-pairs; document order)
- document_symbol:    13/13  GREEN  (of 14 exp.json — the 14th is OUT OF SCOPE, see below)

Total: 112/112 across the four document-order structural features.

## Out of scope by design (documented divergences, NOT gaps)
These are cases where ruby-lsp's behavior comes from its CRuby/Rake/RBS world,
which mruby does not have. Declining them is the conformant choice; the harness
reports them explicitly so they can never silently flip to a FAIL.

- document_symbol/rake — fixture is `rake.rake`. ruby-lsp emits Rake-DSL symbols
  (namespace/task) for `.rake` files. THERE IS NO RAKE IN MRUBY: `.rake`,
  `mrbgem.rake`, and `build_config.rb` run in host CRuby at build time and never
  enter the mruby VM (our only source of truth). We emit no Rake symbols, which
  is correct. `replay_document.py` detects the `.rake` fixture and prints it as
  OUT-OF-SCOPE rather than skipping it by extension accident.
  (The sibling `not_rake.rb` — same DSL in a `.rb` — is the negative case; a
  plain Prism class/module/def walk correctly yields no Rake symbols there.)
- hover / definition RBS prose — ruby-lsp's doc/type content is RBS-sourced; we
  have no RBS. Structure must match on shared symbols; content diverges.
- experimental capabilities — ruby-lsp's addon/Bundler/test-discovery features;
  not advertised by design (standalone VM-reflection server, not a ruby-lsp addon).

## NOT yet scored — official vectors that still need work
These exist in the vendored suite and are NOT yet passing/scored. Counts are
paired-`.rb`-fixture vectors at this pin.

Need the SEMANTIC comparator (sort-aware + shared-subset) before they can score:
- hover:                 7
- definition:            4
- semantic_highlighting: 38

Implemented (oracle-contract-verified) but NOT yet replayed against these vectors:
- code_action_resolve:  22
- code_actions:          5
- code_lens:             5
- diagnostics:           5
- document_link:         2
- inlay_hints:           4
- prepare_rename:        2

Empty upstream dirs (no vectors): code_actions_formatting, formatting — N/A.

Inventory at this pin: 207 exp.json total; 112 scored green; 1 out-of-scope
(document_symbol/rake); ~94 unscored.

A test only goes GREEN when our output equals ruby-lsp's on everything that MUST
be equal (per the semantic rule above). Harness mechanics (request shape) may be
fixed; the vendored expected results may NOT. A diff that can't be proven a
legitimate VM-vs-CRuby / sort / no-Rake divergence is a FAIL.
