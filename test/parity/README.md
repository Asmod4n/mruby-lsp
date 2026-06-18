# ruby-lsp parity harness

Drives BOTH the real ruby-lsp server and ours over stdio on identical input and
compares hover/definition output. ruby-lsp is the oracle — see docs/CONFORMANCE.md
for the rule-by-rule contract tied to ruby-lsp source.

## Running ruby-lsp as the oracle (no-rubygems sandbox)
1. Clone sources: Shopify/ruby-lsp, mtsmfm/language_server-protocol-ruby, prism.
2. Launcher prepends their lib/ to $LOAD_PATH, requires bundler + rbs +
   ruby_lsp/internal, then `RubyLsp::Server.new.start`. RBS 4.1 is built from
   source (ruby/rbs: `cd ext/rbs_extension && ruby extconf.rb && make`) and its
   lib + ext are prepended to $LOAD_PATH so ruby-lsp indexes Ruby core for real.
   NO stubbing — the system RBS 2.8 is too old (ruby-lsp needs rbs >= 3).
3. Workspace needs a Gemfile or the server runs degraded (no indexing -> empty
   hovers). Wait for the $/progress end notification before querying.

## Ours
`ours_launch.rb` sets MRUBY_REFLECT_SO to a built reflect.so and calls
MrubyLsp.start. drive_hover.py speaks LSP over stdio.

## What's verified
title decoration, fence, Definitions label + link shape, 1-based hover link line,
and the full link RANGE: Entry now carries `range` (full def..end span) and
`name_range` (the name token), so hover links render `#Lsl,sc-el,ec` and
definition returns targetRange + name targetSelectionRange BYTE-IDENTICAL to
ruby-lsp (see CONFORMANCE.md). VM entries without a captured range fall back to
the start line.
