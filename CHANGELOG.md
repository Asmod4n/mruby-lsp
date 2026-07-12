# Changelog

All notable changes to mruby-lsp are documented here. This project adheres to
[Semantic Versioning](https://semver.org). Dates are ISO 8601.

## [Unreleased]

First public release. mruby-lsp is a standalone Language Server for mruby that
answers from your project's **live, compiled runtime** rather than a guess about
what mruby "usually" has.

### Language features (full ruby-lsp capability parity)
- Completion, hover, and go-to-definition — including **into the C source** of a
  built-in (addr2line/nm), with C return types and doc comments via clangd.
- Signature help with real overloads, find-references, rename, document &
  workspace symbols, semantic tokens, type hierarchy, inlay hints, folding,
  selection ranges, document highlight, and Prism diagnostics.
- **Live buffer overlay:** classes, methods, `attr_*`, `include`/`prepend`/
  `extend`, `alias`, visibility, `undef`, `Foo = Struct.new`/`Data.define`,
  `Class.new`/`Module.new`, and compound ivar writes (`@x ||= …`) take effect
  as you type, layered over the compiled VM with mruby's real semantics.
- Type inference from the build, overridable by RBS-style `#:` (Ruby) and `//:`
  (C) annotations; declared instance-variable types via `mruby-native-ext-type`.
  Locals born at **binding sites** type like assigned locals: pattern-match
  captures (`in Integer => n`, `expr => x`, `*rest`/`**opts`), block parameters
  (from a buffer def's own `yield`s, or a literal collection's element type for
  core iterators — `[1, 2].each { |e| … }`, `{a: 1}.each { |k, v| … }`,
  `5.times { |i| … }`), numbered params (`_1`), and `it`. Rescue bindings type
  from their class list (`rescue SomeError => e`; bare `rescue` →
  StandardError), and the Kernel conversion casts (`Array(x)`, `String(x)`,
  `Integer(x)`, `Float(x)`, `Hash(x)`, `Rational(x)`, `Complex(x)`) type by
  language definition.
- `#:` annotations are read for **compiled VM methods** from the source file
  the build recorded (Stage 2.5, lazy + memoized; defs found by name, so a
  drifted or freshly annotated file works without a rebuild). A gem annotates
  its API once in its mrblib and every consumer's chains type — the annotation
  is the contract and wins over the irep-derived type, matching buffer-def
  precedence.
- **Trailing local pins** (steep-style): `api = URL("…") #: URL::HTTP` types a
  local whose right-hand side is statically unknowable (per-input factory
  dispatch). The pin wins over inference; a bare class name or a union of them
  is accepted — a generic resolves to nothing rather than a guess.
- **Union types.** A method whose branches all provably return different
  classes types as their union (`Integer | String`) instead of unknown; any
  unproven branch still means unknown — unions never contain guesses, and
  there is no width cap. Producers: buffer-def return inference, RBS-style
  `#:` union annotations (`-> (A | B)`, the escape hatch for C methods and
  per-input factories), trailing local pins, mixed `rescue A, B => e` lists,
  alternation patterns (`in A | B => x`), disagreeing (proven) `yield` sites,
  and mixed-element literal collections. Hover renders the union with a
  definition link per member; completion on a union receiver offers only the
  **intersection** of the members' visible methods. Control-flow guards
  narrow a union back to single classes at the use site: `is_a?`/`kind_of?`/
  `instance_of?` in `if`/`unless` (both branches, and the early-exit
  `return/next/break/raise … if` forms for the rest of the scope),
  `case/when` and `case/in` class conditions (intersect in the branch,
  subtract across earlier branches and in `else`), and truthiness tests
  (dropping `NilClass`/`FalseClass`). Reassignment between guard and use
  cancels narrowing; a guard that would empty the union is ignored.
- **Annotation-free dispatch-table factories.** The Reflector captures every
  compiled value constant's VALUE facts off the live VM at populate (its
  class; for a Hash/Array, each member's class — a new dumb bridge op,
  `const_classes`). Combined with Stage 2.6 — inferring a compiled Ruby
  method's return type from its RECORDED source AST when annotation, irep and
  clangd all come up empty — the `URL(uri)` idiom types itself:
  `SCHEME_CLIENTS[scheme].new` returns the union of the classes the BUILD put
  in the hash (gated, uncompiled protocols aren't in it), `URL("https://…")`
  carries that union through the private `Kernel#URL` (bare calls now reach
  private methods, like the runtime does), and names inferred inside a
  compiled file are qualified through that file's nesting (`Response` inside
  `class URL` → `URL::Response`). `is_a?` narrowing now honors real VM
  ancestry (guarding on a parent class keeps/drops subclass members — and
  several surviving members of one family collapse to the guard class itself,
  so `x.is_a?(URL::HTTP)` reads `URL::HTTP`, not `URL::HTTP | URL::HTTPS`,
  while a single more-precise survivor stays itself), `raise` arms contribute
  no return type, `CONST[i]` on a compiled container of instances types as the
  member-class union, and union completions rank against their first member
  instead of flat (get/post above the Object operators).
  C constructors that return a **fresh instance of their receiver class**
  (`IO.for_fd` → `IO`, `File.for_fd` → `File`) are inferred from the clangd AST —
  including when the fresh object is handed back through one or more helper
  functions (`return io_init(mrb, obj)`) — so completion/hover on the result
  resolve to the right class.

### Snippets / scaffolds (beyond ruby-lsp)
- Completion offers keyword/DSL scaffolds — `class` (named, with `initialize`),
  `def`, `attr_reader`/`writer`/`accessor`, `alias_method`,
  `include`/`prepend`/`extend` — with punctuation pre-filled and tab stops on the
  holes. After a receiver, block scaffolds (`each do |…|`) carry block-parameter
  names READ FROM the method's own source: `yield` / block-call in Ruby;
  `mrb_yield` / `mrb_funcall` in C, tracking the `mrb_get_args` `&` block value. A
  yielded value with no name (`each` yields `self[idx]`, or an argv-family yield)
  becomes an editable `${1:item}` placeholder, never a guessed name. Emitted only
  to clients that advertise `snippetSupport`.

### Debugging
- F5 debugging of `.rb`/`.mrb` via the user's own `mrdb` over the Debug Adapter
  Protocol: breakpoints, step, `info locals`, evaluate. Launches paused on the
  first executable line (stop-on-entry, default on); the launched file is the
  entry point. Native (compiled ELF) debugging is out of scope.

### Verification
- ruby-lsp parity verified live (char-by-char) and against ruby-lsp 0.26.9's own
  vendored expectation vectors; structural features (documentSymbol, foldingRange,
  selectionRange, documentHighlight) byte-equal.
- **CI (GitHub Actions):** every pull request and every push to `main` runs
  the WHOLE suite against the real server — mruby HEAD + the reflection VM are
  built via `mruby-lsp-setup`, then all of `test/overlay` (incl. the live-VM
  semantics pin), the conformance replays over real LSP stdio, the
  `test/consistency` suite under a real LSP client (headless Neovim), and both
  extension suites.
- The extension tests run in a **real VS Code extension host** (official
  `@vscode/test-cli` runner, fixture workspaces, nothing mocked); the
  hand-mocked `vscode` harness had drifted from the product and is gone.
- The conformance replay clients answer the server's unsandboxed-consent
  dialog over `window/showMessageRequest` — the documented client-side consent
  path, now exercised on every replay run — and each replay script now exits
  non-zero on any FAIL (previously always exit 0, requiring a caller to scrape
  the printed summary line).

### Security
- Reflection only — never executes buffer code (no `eval`/`mrb_load_string`).
  On Linux a small STATIC launcher (no dynamic loader, so no `LD_PRELOAD`/`LD_AUDIT`
  can inject into it) confines BEFORE Ruby starts, then `execve`s Ruby on the CLI
  dispatcher. The Landlock FS wall is **two-stage**, because the only spec-portable
  source of the workspace is the LSP `initialize` request — argv and cwd are
  outside the LSP spec and editor-specific (Helix passes no argv), and Landlock
  layers only ever tighten:
  - **Stage 1 (launcher, pre-Ruby):** confine WRITES + EXEC; reads stay open
    (the workspace isn't known yet). Then the seccomp filter as the final step.
  - **Stage 2 (server, post-`initialize`):** once the workspace is known from
    `rootUri`/`workspaceFolders`, a tiny CRuby ext (`MrubyLsp::Landlock`) stacks a
    READ wall scoped to the project + the dirs Ruby itself needs. If the kernel
    headers don't name Landlock the ext defines nothing and the server degrades.
  The server learns whether it is confined with NO env var and NO flag, by reading
  `/proc/self/status` (Landlock is not introspectable; the seccomp filter, set only
  after the wall is up, is the truthful marker). If Landlock is unavailable it
  FAILS CLOSED: it asks for explicit consent through a native dialog
  (`window/showMessageRequest`, chosen by the client's declared capability — not a
  tty guess) and, without consent, announces the shutdown (`window/showMessage`)
  and exits rather than running unsandboxed silently. Editors are fed the workspace
  only through `initialize` (no argv to the binary). Platforms with no Landlock
  (macOS/Windows) run as before. The user's build tree and config are never
  modified; setup state lives outside the workspace.
- The OFFLINE BUILD PHASE (`mruby-lsp-setup`) is network-sealed the same spirit
  and now FAILS CLOSED. A seccomp-BPF filter denies `AF_INET`/`AF_INET6`
  `socket()` while the fetched build code (`rake`/`gcc`/`mrbgem.rake`) runs, so it
  can't phone home or pull more code; `AF_UNIX`, pipes, and file I/O stay intact.
  The filter covers x86_64/aarch64 and **kills foreign-arch syscalls** (closing the
  i386/x32 compat-ABI bypass), and the wrapper refuses to exec the build unsealed:
  where the seal can't engage on Linux (old kernel, unhardcoded CPU arch) the build
  is never run unsealed silently — setup asks for **explicit consent** (a tty
  prompt, or the editor's consent dialog), exactly like the Landlock wall. Non-Linux
  has no such primitive and builds as before.

### Build & release
- **Deliberate SemVer.** `lib/mruby_lsp/version.rb` is the single hand-set
  version; no build/install/package task bumps it. Releases use explicit
  `rake bump:patch` / `bump:minor` / `bump:major` (each writes `version.rb` +
  the extension `package.json` and pins `value_bridge` in lockstep). A
  same-version `rake install` reinstalls cleanly (`gem install --force`).
- **External deps and build artifacts no longer live in the repo.** The
  previously committed `prism` / `language_server-protocol` `.gem` files and the
  vendored-gem `manifest.json` are removed; the full external runtime-dep closure
  is fetched into the `.vsix` at package time, so the source tree stays
  source-only. The `.vsix` remains self-contained for offline install.
- **One `build/` directory for everything transient** (`build/gems`,
  `build/stage`, the packaged `build/mruby-lsp-<v>.vsix`); `rake clobber` removes
  it. The extension now reinstalls its bundled gems by a CONTENT digest (a
  `bundle` field in the manifest) rather than the version, so a changed gem set
  triggers exactly one reinstall, independent of the SemVer.

### Fixed
- **Bare `module_function` follows mruby HEAD** (≥ 2026-07, now CRuby-like):
  defs after a bare `module_function` in a module body get a public singleton
  copy and a **private** instance method, until a bare visibility verb resets
  the scope. The overlay previously modeled the bare form as inert — which
  mruby itself changed. The explicit-arg form is unchanged (public singleton
  copy, instance stays public — still an mruby divergence from CRuby). Caught
  by the live-VM pin `test/overlay/mruby_semantics_test.rb`, now re-pinned to
  the new behavior.
- The workspace-refresh gate **logs its verdict** per workspace on every
  activation (`refresh gate: <root> native=… shipped=… -> current|STALE`),
  and the server **warns once** when a workspace's reflect `.so` predates a
  bridge op the Ruby code wants (degraded, not crashed — but no longer
  silently). A silent gate made "why didn't it rebuild?" unanswerable from
  the output panel.
- The extension's post-install workspace refresh is gated on **content, not
  version**: the bundle manifest's `native` fingerprint is compared per
  consented workspace against the cache's recorded `native.sha256`, and setup
  runs only where they differ. The old gate (`globalState.lastVersion`) never
  fired on a same-version dev `rake vscode:install` — VS Code keeps
  globalState across uninstall/reinstall — so changed native code silently
  kept running against stale workspace builds. No version bump is needed to
  iterate: identical content is a no-op, changed content rebuilds exactly the
  stale workspaces.
- **Presym coherence guard**: a shift in mruby's compile-time symbol table
  (`include/mruby/presym/id.h` — an updated mruby head such as the Prism-based
  compiler switch, a re-fetched gem at a newer revision, a changed gem set)
  used to poison the incrementally rebuilt workspace cache: mtime-satisfied
  objects kept OLD symbol IDs baked in and decoded constants as the wrong
  symbols at runtime (server crash at startup: `unexpected Platform::OS
  :is_a?`), recurring on every gem update. Setup now stamps the table's digest
  per cache (`presym.sha256`) and, when a build ends with a different table
  than the cache was built against, wipes and rebuilds once from clean.
- **VM sanity probe (self-healing setup)**: after compiling the reflect `.so`,
  setup loads the built VM in a child process and reads its `Platform` pair;
  a garbage symbol, raise, or crash marks the cache incoherent and triggers
  the clean rebuild automatically — a workspace poisoned before these guards
  existed heals itself on the next update, no manual reset required. Healthy
  caches pay only the probe; the incremental fast path is unchanged.
- The per-workspace clean-rebuild gate **fails closed on a missing fingerprint
  marker**: an existing cached build with no recorded `native.sha256` (a
  workspace set up before the gate existed) is now wiped and rebuilt instead of
  being silently adopted as current. Previously setup skipped the wipe AND
  stamped the current digest, permanently laundering the stale cache — no later
  release (the digest is version-immune by design) could ever trigger the
  rebuild, and the server would crash at startup on VM invariants the stale
  archive lacks (e.g. mruby-platform's `Platform` constants). Field symptom:
  update logs showing "up to date, skipping" with a build summary that lists
  the gem — the summary prints the evaluated config, not the archive.
- The editor's **Rebuild Now** command now runs the actual clean rebuild
  (`mruby-lsp-update rebuild`: clears the cached build + reflect_so, then
  setup). It was an alias of Build (another incremental setup) — exactly the
  path a stale cache no-ops — so "rebuild" didn't rebuild.
- New **Reset Workspace Cache** command (`mruby-lsp-update reset <project>`):
  deletes the workspace's entire cache — build, fetched gem clones, reflection
  artifacts, the recorded fingerprint — and sets up from scratch. The
  user-facing recovery for a wedged cache (a half-failed update, a stale
  pre-gate build); previously the only way out was deleting
  `~/.cache/mruby-lsp/<workspace>` by hand. Unlike `rebuild` it also clears
  the fetched clones and works even when discovery no longer recognizes the
  cache as set up.
- Completion now shows a C method's **real parameter names** (`String#index` →
  `(sub, pos = ...)`) instead of the aspec's `argN` placeholders, matching what
  hover and signature help already showed. All three render their signature
  through one seam (`Index#display_params`), so the same method can never read
  `(arg1, arg2)` in the completion list and `(sub, pos)` on hover. The real names
  come from `mrb_get_args` via clangd, resolved lazily and memoized; with clangd
  absent the three fall back to the aspec form together. New real-LSP-client
  consistency tests (`test/consistency/`) assert this agreement so it can't drift
  again.
- Install: the compiled launchers (`mruby-lsp` / `mruby-lsp-setup` /
  `mruby-lsp-update` / `mruby-lsp-nonet`) now go to `Gem.bindir` — the
  configured EXECUTABLE DIRECTORY (honors `--bindir`, user vs system install,
  rbenv) — so they are on PATH (`mruby-lsp-setup` resolves as a command). There
  are no RubyGems binstubs sitting beside them (`spec.executables` is empty): the
  launcher bakes in the Ruby interpreter + the gem's `lib/` dir and execve's the
  CLI dispatcher (`lib/mruby_lsp/cli.rb`) directly, handing it the command's role,
  so nothing needs PATH resolution. A prior version derived the bindir with path
  math and overshot to `Gem.dir/bin` — a directory nobody knows: not on PATH, and
  untracked by RubyGems, so its binaries were orphaned on `gem uninstall`.
- Install/uninstall are now symmetric: a `lib/rubygems_plugin.rb` post-uninstall
  hook removes everything `gem uninstall` can't — the non-declared launcher /
  nonet files, plus the out-of-tree records (`install.json`, per-workspace setup
  state, and the build caches under `~/.local/share/mruby-lsp` and
  `~/.cache/mruby-lsp`) — once the last version is gone. Nothing is left behind.
- All of our own paths (`install.json`, setup state, build cache) resolve from a
  FIXED passwd-home base (the same env-free rule the C launcher already uses),
  never `$XDG_DATA_HOME`/`$XDG_CACHE_HOME`/`$HOME`, so a stray environment can't
  relocate where records land — install, setup, server, and the editor extension
  always agree on the one directory.
