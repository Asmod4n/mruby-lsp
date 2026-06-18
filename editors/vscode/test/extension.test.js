// Headless extension tests — NO VSCode download, NO Electron. We mock the
// `vscode` and `vscode-languageclient/node` modules and drive the COMPILED
// extension (out/extension.js) directly under mocha/node. This exercises the
// real activation + LSP-client glue: command registration, workspace detection,
// the not-set-up build offer, and ServerOptions construction (which also
// validates the stateDir/slug keying against a real config.json on disk).
"use strict";
const assert = require("assert");
const Module = require("module");
const path = require("path");
const fs = require("fs");
const os = require("os");

const EXT = path.resolve(__dirname, "..", "out", "extension.js");

// ── mutable mock state, reset per test via freshMocks() ──────────────────────
let mocks;
function freshMocks() {
  const commands = [];
  const errors = [];
  const infos = [];
  let infoAnswer; // what showInformationMessage resolves to
  const lcCalls = []; // captured LanguageClient constructions
  let started = false;

  const vscode = {
    workspace: {
      workspaceFolders: undefined,
      findFiles: async () => [],
      getConfiguration: () => ({ get: (_k) => undefined }),
    },
    window: {
      createOutputChannel: () => ({ appendLine() {}, dispose() {}, show() {} }),
      createTerminal: () => ({ sendText() {}, show() {}, dispose() {} }),
      showErrorMessage: (m) => { errors.push(m); return Promise.resolve(undefined); },
      showInformationMessage: (m) => { infos.push(m); return Promise.resolve(infoAnswer); },
    },
    commands: {
      registerCommand: (id, cb) => { commands.push({ id, cb }); return { dispose() {} }; },
    },
    RelativePattern: class { constructor(base, pattern) { this.base = base; this.pattern = pattern; } },
  };

  const lc = {
    LanguageClient: class {
      constructor(id, name, serverOptions, clientOptions) {
        lcCalls.push({ id, name, serverOptions, clientOptions });
      }
      start() { started = true; return Promise.resolve(); }
      stop() { return Promise.resolve(); }
    },
    TransportKind: { stdio: 0 },
  };

  mocks = {
    vscode, lc, commands, errors, infos, lcCalls,
    setInfoAnswer: (a) => { infoAnswer = a; },
    started: () => started,
  };
  return mocks;
}

// Inject mocks for the two host-provided modules; everything else loads normally.
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === "vscode") return mocks.vscode;
  if (request === "vscode-languageclient/node") return mocks.lc;
  return origLoad.apply(this, arguments);
};

// Load a FRESH copy of the extension (module-scope `output`/`client` reset).
function loadExtension() {
  delete require.cache[require.resolve(EXT)];
  return require(EXT);
}

const tick = () => new Promise((r) => setTimeout(r, 30));

// slug must stay byte-identical to Ruby's path_slug (build_discovery.rb).
function slug(abs) {
  return abs.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+/, "");
}

suite("mruby-lsp extension (headless)", () => {
  const DECLARED = [
    "mrubyLsp.build", "mrubyLsp.rebuild", "mrubyLsp.restart",
    "mrubyLsp.stop", "mrubyLsp.updateMruby", "mrubyLsp.updateGems",
  ];

  test("activate registers exactly the declared commands", async () => {
    freshMocks();
    const ext = loadExtension();
    ext.activate({ subscriptions: [] });
    await tick();
    const ids = mocks.commands.map((c) => c.id).sort();
    assert.deepStrictEqual(ids, [...DECLARED].sort());
  });

  test("non-mruby workspace stays idle (no client, no error)", async () => {
    freshMocks();
    mocks.vscode.workspace.workspaceFolders = [{ uri: { fsPath: "/tmp/not-mruby" } }];
    mocks.vscode.workspace.findFiles = async () => []; // no include/mruby.h
    const ext = loadExtension();
    ext.activate({ subscriptions: [] });
    await tick();
    assert.strictEqual(mocks.lcCalls.length, 0, "no LanguageClient created");
    assert.strictEqual(mocks.errors.length, 0, "no error surfaced");
  });

  test("mruby workspace, not set up -> offers Build (no client yet)", async () => {
    freshMocks();
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "mrb-ws-"));
    mocks.vscode.workspace.workspaceFolders = [{ uri: { fsPath: root } }];
    mocks.vscode.workspace.findFiles = async () => [{ fsPath: path.join(root, "include", "mruby.h") }];
    mocks.setInfoAnswer("Not now"); // decline the build
    const ext = loadExtension();
    ext.activate({ subscriptions: [] });
    await tick();
    assert.ok(mocks.infos.some((m) => /set up/i.test(m)), "build prompt shown");
    assert.strictEqual(mocks.lcCalls.length, 0, "no client until built");
  });

  test("mruby workspace, set up -> starts client with correct ServerOptions", async () => {
    freshMocks();
    const xdg = fs.mkdtempSync(path.join(os.tmpdir(), "xdg-"));
    process.env["XDG_DATA_HOME"] = xdg;
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "mrb-ws-"));
    // Write the SAME state file the Ruby side writes, at the SAME slug-keyed path.
    const stateDir = path.join(xdg, "mruby-lsp", "workspaces", slug(path.resolve(root)));
    fs.mkdirSync(stateDir, { recursive: true });
    fs.writeFileSync(path.join(stateDir, "config.json"), JSON.stringify({ setup: { done: true } }));

    mocks.vscode.workspace.workspaceFolders = [{ uri: { fsPath: root } }];
    mocks.vscode.workspace.findFiles = async () => [{ fsPath: path.join(root, "include", "mruby.h") }];
    mocks.vscode.workspace.getConfiguration = () => ({ get: (k) => (k === "serverCommand" ? "mruby-lsp" : undefined) });

    const ext = loadExtension();
    ext.activate({ subscriptions: [] });
    await tick();

    assert.strictEqual(mocks.lcCalls.length, 1, "one LanguageClient created");
    const so = mocks.lcCalls[0].serverOptions;
    assert.strictEqual(so.run.command, "mruby-lsp", "spawns the configured binary");
    assert.deepStrictEqual(so.run.args, [root], "passes the workspace root as argv[1]");
    assert.strictEqual(so.run.options.cwd, root, "cwd is the workspace root");
    assert.ok(mocks.started(), "client.start() was called");
    const sel = mocks.lcCalls[0].clientOptions.documentSelector;
    assert.ok(sel.some((d) => d.language === "ruby"), "selects ruby documents");
  });

  suiteTeardown(() => { Module._load = origLoad; });
});
