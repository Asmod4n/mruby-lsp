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
  can inject into it) confines BEFORE Ruby starts — Landlock FS wall + a seccomp
  filter as the final step — then `execve`s Ruby directly on the entry script.
  The server learns whether it is confined with NO env var and NO flag, by reading
  `/proc/self/status` (Landlock is not introspectable; the seccomp filter, set only
  after the wall is up, is the truthful marker). If Landlock is unavailable it
  FAILS CLOSED: it asks for explicit consent through a native dialog
  (`window/showMessageRequest`, chosen by the client's declared capability — not a
  tty guess) and, without consent, announces the shutdown (`window/showMessage`)
  and exits rather than running unsandboxed silently. Platforms with no Landlock
  (macOS/Windows) run as before. The user's build tree and config are never
  modified; setup state lives outside the workspace.

### Fixed
- Install: the compiled launchers (`mruby-lsp` / `mruby-lsp-setup` /
  `mruby-lsp-update` / `mruby-lsp-nonet`) now go to `Gem.bindir` — the
  configured EXECUTABLE DIRECTORY (honors `--bindir`, user vs system install,
  rbenv) — alongside RubyGems' own `-server` / `-setup-impl` / `-update-impl`
  binstubs. They are therefore on PATH (so `mruby-lsp-setup` resolves as a
  command), and the launcher's `/proc/self/exe` impl-sibling contract holds in
  that same dir. A prior version derived the bindir with path math and overshot
  to `Gem.dir/bin` — a directory nobody knows: not on PATH, and untracked by
  RubyGems, so its binaries were orphaned on `gem uninstall`.
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
