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
