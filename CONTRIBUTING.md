# Contributing to mruby-lsp

Thanks for helping out. This is a standalone LSP server for mruby whose source of
truth is the **live, compiled mruby VM** — not RBS, not CRuby conventions, not
static file indexing. Keep that premise in mind; it drives most design decisions.

## Layout

- `lib/mruby_lsp/` — the server (Ruby): LSP transport, the VM-reflection index,
  and every feature (completion, hover, definition, …). The buffer **overlay**
  (`buffer_harvester.rb`) parses open/unsaved files with Prism so edits count
  before a rebuild.
- `ext/mruby_reflect/` + `vendor/value_bridge/` — the C bridge that reflects a
  built `libmruby` into the host Ruby process. It is a **dumb FFI conduit**: all
  logic lives in Ruby; the VM decides, C never dispatches.
- `editors/vscode/` — the VS Code / VSCodium extension (language client + the
  `mruby` debug adapter over `mrdb`).
- `test/overlay/` — fast, prism-only unit tests (no VM needed).
  `test/conformance/` — replays ruby-lsp's own expectation vectors against our
  server; `test/parity/` — drives the real ruby-lsp as an oracle.

## Build & run from a checkout

```bash
# run the server (host Ruby) from the checkout, via the CLI dispatcher:
ruby -Ilib -r mruby_lsp/cli -e 'MrubyLsp::CLI.run(ARGV.shift, ARGV)' -- server /path/to/project
cc -O2 -o /tmp/mruby-lsp ext/mruby_lsp_launcher/launcher.c   # build the sandbox launcher
cd editors/vscode && npm install && npm run compile     # build the extension
```

Full editor install and per-project setup are in the [README](README.md)
(`rake vscode:install` / `rake install` + `mruby-lsp-setup`).

### Build layout and versioning

Everything transient builds under **`build/`** — nothing lands in the source
tree:

- `build/gems/` — the two gems we author (`mruby-lsp`, `value_bridge`), built
  once by `rake gem:build` at the current version.
- `build/stage/` — the `.vsix` assembly area (staged extension source + the
  fetched external-gem closure).
- `build/mruby-lsp-<v>.vsix` — the packaged extension.

`rake clobber` removes `build/` (and `mruby/build/`) entirely — the single
cleanup command.

**Versioning is deliberate.** `lib/mruby_lsp/version.rb` is the single,
hand-set SemVer source of truth. No build, install, or package task bumps it; a
same-version `rake install` reinstalls cleanly (`gem install --force`) so you can
iterate without bumping. To cut a release, run an explicit bump (each writes
`version.rb` + the extension `package.json` and pins `value_bridge` in lockstep):

```bash
rake bump:patch   # 0.1.120 -> 0.1.121
rake bump:minor   # 0.1.120 -> 0.2.0
rake bump:major   # 0.1.120 -> 1.0.0
```

External runtime deps (prism, rbs, language_server-protocol, …) are **not** kept
in the repo: `rake vscode:package` fetches the full source-gem closure into the
`.vsix` stage at package time (needs network), so the shipped `.vsix` is
self-contained but the repo stays source-only.

Packaging the extension (`rake vscode:package` / `vscode:install`) stages the
sources with `rsync` when present (it ships by default on most Linux/macOS but is
NOT in the FreeBSD base system — `pkg install rsync` there); without `rsync` it
falls back to an equivalent in-Rakefile copy that preserves mtimes.

## Tests

```bash
cd test/overlay && for t in *_test.rb; do ruby "$t"; done   # unit (prism-only)
cd editors/vscode && npm test                               # extension + debug adapter
```

The conformance + parity suites (`test/conformance/README.md`,
`test/parity/README.md`) need a built reflection VM and, for parity, ruby-lsp
built from source; both READMEs document the procedure.

## House rules (non-negotiable)

- **Verify by running.** Drive the server over real LSP stdio; static inspection
  doesn't count as done.
- **No `mrb_load_string` / eval** in any mruby context. Reading the
  already-loaded image is fine; executing buffer code is the security line.
- **No regex on structured input** (Ruby, JSON, HTML, compiler command lines,
  structured machine output). Ruby → Prism; C locations → addr2line/nm; reflection
  → consumed structurally. Keep regex out of hot paths.
- **C is a dumb bridge**, and it contains **nothing fuzzable** — all parsing and
  logic is host Ruby.
- **Degrade, don't crash.** Optional subsystems (e.g. clangd) are BYO and may be
  absent or die mid-session — switch the feature off and keep the server alive.

For the working conventions (commit author/trailers, patch delivery) see
[`AGENTS.md`](AGENTS.md); for hard-won pitfalls before touching native/build code
read [`docs/GOTCHAS.md`](docs/GOTCHAS.md); the ruby-lsp conformance contract is in
[`docs/CONFORMANCE.md`](docs/CONFORMANCE.md). Project state, open work, and the
roadmap live in the **GitHub issue tracker**.
