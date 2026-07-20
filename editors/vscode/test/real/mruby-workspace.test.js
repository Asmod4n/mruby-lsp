// Runs INSIDE a real extension host (@vscode/test-cli, workspace =
// test/fixtures/mruby-ws — carries include/mruby.h). Exercises the mruby
// branch of the startup sequence against the real host: detection via the
// real findFiles, the not-set-up gate (isSetUp reads the out-of-workspace
// cache, absent here), and the real command paths a user can invoke in this
// state. The set-up/served path needs a built reflection VM and is covered by
// the nightly conformance job, not here.
"use strict";
const assert = require("assert");
const vscode = require("vscode");

suite("activation in an mruby workspace (not set up)", () => {
  let ext;

  suiteSetup(async () => {
    ext = vscode.extensions.getExtension("Asmod4n.mruby-lsp");
    assert.ok(ext, "extension found under its manifest id");
    await ext.activate();
    // Startup detects the workspace and offers the build asynchronously; give
    // the sequence a beat so a crash in it surfaces before we assert health.
    await new Promise((r) => setTimeout(r, 1500));
  });

  test("workspace fixture carries the mruby marker", async () => {
    const found = await vscode.workspace.findFiles("**/include/mruby.h", null, 1);
    assert.strictEqual(found.length, 1, "fixture exposes include/mruby.h to the host");
  });

  test("survives the detection + not-set-up offer path", () => {
    assert.strictEqual(ext.isActive, true);
  });

  test("Build command runs its real not-installed path without throwing", async () => {
    // No mruby-lsp gem is installed in the test host, so this walks
    // gemInstalled() -> bootstrapGem() -> surfaced error, and must resolve.
    // (restart is NOT exercised here: in a not-set-up workspace it re-enters
    // the build offer, which blocks on a real user answer by design.)
    await vscode.commands.executeCommand("mrubyLsp.build");
  });
});
