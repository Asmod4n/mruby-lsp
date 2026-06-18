# VS Code extension — gotchas defended (learned the hard way last build)

1. Same-version .vsix won't reinstall. VSCodium no-ops install when version
   matches -> you test stale code. BUMP version every package; or fully
   uninstall + verify the extension dir is gone before reinstalling.

2. node_modules missing from the .vsix -> activation throws silently (failed
   top-level require of vscode-languageclient/node) -> activate never runs ->
   no commands. DEFENDED: .vscodeignore keeps node_modules; verified the vsix
   contains node_modules/vscode-languageclient (63 files).

3. Unhandled promise rejections dead-end activation. DEFENDED: startClient is
   void-caught in activate; every await is wrapped; failures surface via
   showErrorMessage + the output channel, never silent.

4. Commands declared in package.json but not registered (or vice versa) ->
   command vanishes / does nothing. DEFENDED: all six (build, rebuild, restart,
   stop, update mruby, update gems) are both declared AND registered; verified
   against the packaged manifest.

5. Activation events too narrow -> never activates. DEFENDED:
   workspaceContains:**/include/mruby.h + onStartupFinished.

6. The decisive diagnostic when something's wrong is the EXTENSION HOST LOG
   (Command Palette -> "Developer: Show Logs..." -> "Extension Host"), not
   source inspection — the installed artifact can be stale while source is fine.
   The extension also logs to its own "mruby-lsp" output channel.

## Install
    codium --install-extension mruby-lsp-<version>.vsix --force
(--force makes a same-version reinstall actually take.)
Then reload the window. Open an mruby project (one with a *.rb.lock). If not yet
set up, click "Build" on the prompt (or run "mruby-lsp: Build/Setup Server For
This Project"). Server features come up once the build finishes + you restart.
