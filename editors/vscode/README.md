# mruby-lsp — VS Code / VSCodium extension

The editor client for the **mruby-lsp** server (see the repository's root
`README.md`). It is a **standalone**
language-client: it talks to Microsoft's `vscode-languageclient` directly and
launches the `mruby-lsp` server binary. There is no ruby-lsp interaction — not
the extension, not a fork, not a PATH shim.

The server's source of truth is the live, compiled mruby VM. The extension only
launches it, points it at the workspace, and exposes the build/update commands.

## Install

From a clone of the repo (one command, needs the `code`/`codium` CLI on PATH):

```bash
rake vscode:install
```

This packages the extension with the server and all runtime gems bundled,
removes any stale copy, and installs into your editor. Reload the window
afterward.

To install a prebuilt `.vsix` by hand (`--force` makes a same-version reinstall
actually take):

```bash
code --install-extension mruby-lsp-<version>.vsix --force
```

The extension finds the server via `$XDG_DATA_HOME/mruby-lsp/install.json`
(written by the gem's install hook), so you don't have to edit PATH. If the gem
isn't installed at all, the extension installs it itself via
`gem install --user-install mruby-lsp`.

## Setting up a project

Everything below — installing the bundled gems, building, and starting the
server — requires **Workspace Trust**. In an untrusted workspace the extension
stays idle (its commands are still registered) and runs the deferred startup the
moment you trust the folder. VS Code's trust prompt is the gate; it stands in
front of the "Build?" question below.

The extension treats a folder as mruby when it contains `include/mruby.h`. Build
your `build_config.rb` once (so a `*.rb.lock` exists for setup discovery), then:

- **Not set up yet** (no built reflection artifact in the cache): the extension
  only **offers** a Build button — it never builds an un-set-up project on its
  own. Build/rebuild run `mruby-lsp-setup` in a terminal.
- **Already built**: after an extension *update* the extension re-runs
  `mruby-lsp-setup` for workspaces you have previously built, so the server stays
  in sync with the new version.
- On activation it also ensures its own bundled runtime gems are installed into
  the extension's global storage (not your project).

## Commands

Palette prefix `mruby-lsp:`. All six are declared in `package.json` and
registered in `extension.js`:

- **Build/Setup Server For This Project** (`mrubyLsp.build`)
- **Rebuild Now** (`mrubyLsp.rebuild`)
- **Restart Server** (`mrubyLsp.restart`)
- **Stop Server** (`mrubyLsp.stop`)
- **Update mruby** (`mrubyLsp.updateMruby`)
- **Update Pulled-in Gems** (`mrubyLsp.updateGems`)

## Settings

- `mrubyLsp.rebuildOnSave` — rebuild the project on save (consent-gated;
  default off).
- `mrubyLsp.requestTimeout` — LSP request timeout.
- `mrubyLsp.rubyPath` — Ruby interpreter used to launch the server.
- `mrubyLsp.trace.server` — off by default; `verbose` logs the full LSP
  conversation to the output tab.

## Activation

`workspaceContains:**/include/mruby.h` (an mruby project on disk) plus
`onStartupFinished` (so the bundled-gem check can run once after the editor
finishes starting). The extension re-confirms the workspace is mruby
(`isMrubyWorkspace`) before doing anything project-specific, and the whole
startup (gem install, post-update rebuild, server start) is gated on Workspace
Trust — `package.json` declares `capabilities.untrustedWorkspaces: "limited"`, so
in an untrusted folder the extension loads but does no build/install/start until
trust is granted.

## Development & testing

The extension is thin LSP-client glue, so it's tested **headlessly** — no
VSCode download, no Electron:

```bash
cd editors/vscode && npm install && npm test
```

`pretest` compiles, `mocha` runs `test/**/*.test.js`. The suite mocks the
`vscode` and `vscode-languageclient/node` modules and drives the compiled
`out/extension.js`.

Read `GOTCHAS.md` (in this folder) before changing packaging or activation — the
hard-won pitfalls (same-version reinstall, node_modules-in-vsix, declared ==
registered commands, activation breadth, the extension-host log as the real
diagnostic) are recorded there.
