// Official VS Code extension-test runner (@vscode/test-cli): each config
// launches a REAL extension host (downloaded once into .vscode-test/) with a
// fixture workspace and runs the matching spec inside it — no mocked vscode
// API, so activation drift (context shape, command surface, state protocol)
// fails here instead of shipping. Run all: `npm test`; one: `vscode-test
// --label mruby-ws`. CI runs the same under xvfb (see .github/workflows).
import { defineConfig } from "@vscode/test-cli";

export default defineConfig([
  {
    label: "plain-ws",
    files: "test/real/activation.test.js",
    workspaceFolder: "test/fixtures/plain-ws",
    mocha: { ui: "tdd", timeout: 60000 },
    // Trust feature off = fixture workspaces are trusted, so the activation
    // startup sequence actually runs instead of deferring.
    launchArgs: ["--disable-workspace-trust"],
  },
  {
    label: "mruby-ws",
    files: "test/real/mruby-workspace.test.js",
    workspaceFolder: "test/fixtures/mruby-ws",
    mocha: { ui: "tdd", timeout: 60000 },
    launchArgs: ["--disable-workspace-trust"],
  },
]);
