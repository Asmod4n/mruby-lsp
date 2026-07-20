// Runs INSIDE a real extension host (@vscode/test-cli, workspace =
// test/fixtures/plain-ws — no mruby marker). Everything here is the real API:
// a fake vscode module can't drift from the host, so a context-shape or
// command-surface regression fails here instead of in a user's editor.
"use strict";
const assert = require("assert");
const vscode = require("vscode");

suite("activation in a non-mruby workspace", () => {
  let ext;

  suiteSetup(async () => {
    ext = vscode.extensions.getExtension("Asmod4n.mruby-lsp");
    assert.ok(ext, "extension found under its manifest id");
    await ext.activate();
  });

  test("activates cleanly", () => {
    assert.strictEqual(ext.isActive, true);
  });

  test("registers exactly the commands the manifest declares", async () => {
    // DECLARED comes from the live manifest, not a hand-kept list — adding a
    // command in package.json without registering it (or vice versa) fails.
    const declared = ext.packageJSON.contributes.commands.map((c) => c.command).sort();
    const registered = (await vscode.commands.getCommands(true))
      .filter((c) => c.startsWith("mrubyLsp."))
      .sort();
    assert.deepStrictEqual(registered, declared);
  });

  test("stays idle: stop with no client is a clean no-op", async () => {
    await vscode.commands.executeCommand("mrubyLsp.stop");
  });
});
