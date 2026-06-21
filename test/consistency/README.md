# Cross-feature consistency tests

One premise: **ask the LSP the same thing through different endpoints and you get
the same logical answer.** A completion item, a hover markdown blob, a signature
label, a `Location`, a `WorkspaceEdit` — the *formatting* differs by design; the
*facts* behind them must not. These tests pin the facts and let each feature
render them however it likes, so a fix in one place can never silently drift from
another (the bug that started this: completion showed a C method's parameters as
`(arg1, arg2)` while hover/signatureHelp showed the real `(sub, pos)`).

They are driven by a **real LSP client** — Neovim's built-in `vim.lsp` — against
the **real server** and a **real mruby-HEAD reflection VM** + clangd. No mocks,
no stubs, no hand-rolled JSON-RPC.

## Tests

- `feature_consistency.lua` — for a method call, `params` (completion
  `labelDetails.detail` / hover signature / signatureHelp label) and `file`
  (completion `labelDetails.description` / hover Definitions link /
  `textDocument/definition`) must agree.
- `occurrence_consistency.lua` — "where does symbol X occur?" asked via
  `references`, `documentHighlight`, and `rename` must yield the same position
  set **where all three are contracted to operate**: for a CONSTANT all three
  agree; for a LOCAL, references == documentHighlight while `rename` is `null`
  **by design** (rename is constants-only, matching ruby-lsp). Both halves are
  asserted, so neither the agreement nor the intentional boundary can regress.
- `lsp_client.lua` — the shared client helper (start server, answer the
  unsandboxed-consent dialog, request, await readiness). One copy of the
  boilerplate — the very thing these tests exist to enforce.

## Running

Needs a project that has been built and set up (`mruby-lsp-setup`), and clangd
on PATH (or `MRUBY_LSP_CLANGD`). Point the env at the setup output (`paths.env`):

```bash
export MRUBY_REFLECT_SO=<from the project's paths.env>   # reflect_so=…
export MRUBY_LSP_WS=/path/to/the/setup/project            # default /tmp/proj
export MRUBY_LSP_REPO="$PWD"                               # server checkout (-Ilib)

nvim --headless -l test/consistency/feature_consistency.lua
nvim --headless -l test/consistency/occurrence_consistency.lua
```

Each exits non-zero and prints the diverging values when a fact disagrees, `0`
when every endpoint agrees. Without clangd the C real-name path is off and the
features fall back to the aspec form *together* — still consistent, just less
precise.
