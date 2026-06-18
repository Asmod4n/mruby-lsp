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
  Linux launcher self-confines via Landlock/seccomp; the user's build tree and
  build config are never modified; setup state lives outside the workspace.

### Fixed
- Install: the launcher and its impl sibling now share a bindir on setups
  where `gem env`'s EXECUTABLE DIRECTORY differs from `gem_dir/bin` (rbenv,
  any custom RubyGems prefix). Previously the install hook wrote launchers
  to a self-derived `gem_dir/bin` while RubyGems wrote the `-server` /
  `-setup-impl` / `-update-impl` binstubs to `Gem.bindir`; the launcher
  resolves its impl via `/proc/self/exe` (PATH is bypassed by design), so
  every launcher aborted with `could not locate '…' next to this launcher`.
  Both now go to `Gem.bindir`. Stock installs (where the two paths coincide)
  are unchanged. See `docs/GOTCHAS.md`.
