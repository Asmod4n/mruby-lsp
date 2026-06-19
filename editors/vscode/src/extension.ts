import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import * as cp from "child_process";
import * as os from "os";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  RevealOutputChannelOn,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;
let output: vscode.OutputChannel;

// Absolute path to the installed vendored bundle (a GEM_PATH dir holding the
// server gem + all its deps), set during activation by ensureBundle(). When set,
// the server and setup run from THIS bundle — no global gem install, no PATH.
// It lives under the extension's globalStorage, which VS Code deletes when the
// user uninstalls the extension: nothing is left behind on their machine.
let bundlePath: string | undefined;

// Find a `ruby` to drive `gem install` with. mruby projects need a Ruby anyway,
// so one is present; we just have to locate it without assuming a login PATH
// (desktop-launched editors often don't inherit the shell PATH). Order: an
// explicit setting, then the runtime's own PATH, then common locations.
function findRuby(): string | undefined {
  const cfg = vscode.workspace.getConfiguration("mrubyLsp");
  const explicit = cfg.get<string>("rubyPath", "").trim();
  if (explicit && fs.existsSync(explicit)) return explicit;

  const exe = process.platform === "win32" ? "ruby.exe" : "ruby";
  const dirs = (process.env["PATH"] ?? "").split(path.delimiter).filter(Boolean);
  // Common install roots not always on a GUI app's PATH.
  dirs.push("/usr/bin", "/usr/local/bin", "/opt/homebrew/bin",
            path.join(process.env["HOME"] ?? "", ".rbenv", "shims"),
            path.join(process.env["HOME"] ?? "", ".rvm", "rubies", "default", "bin"));
  for (const d of dirs) {
    const p = path.join(d, exe);
    if (fs.existsSync(p)) return p;
  }
  return undefined;
}

// The version the vendored bundle ships (from vendor/gems/manifest.json). The
// install is keyed off this: reinstall only when it changes, so a marketplace
// UPDATE (new .vsix => new manifest version) triggers exactly one reinstall and
// nothing else does. Content-based, immune to file mtimes.
function vendoredVersion(extPath: string): string | undefined {
  try {
    const m = path.join(extPath, "vendor", "gems", "manifest.json");
    if (!fs.existsSync(m)) return undefined;
    return JSON.parse(fs.readFileSync(m, "utf8"))["mruby-lsp"];
  } catch {
    return undefined;
  }
}

// Install the vendored gems into a writable GEM_PATH under globalStorage, once
// per version. Returns the bundle path, or undefined if there is no vendored
// bundle (dev checkout) or the install failed. Idempotent: if the installed
// marker already matches the vendored version, it's a no-op.
async function ensureBundle(context: vscode.ExtensionContext): Promise<string | undefined> {
  const extPath = context.extensionPath;
  const vendorDir = path.join(extPath, "vendor", "gems");
  const version = vendoredVersion(extPath);
  if (!version || !fs.existsSync(vendorDir)) {
    output.appendLine("bundle: no vendored gems in this build (dev checkout?) — using global discovery");
    return undefined;
  }

  // globalStorage is writable AND removed on uninstall. Install per version so
  // an extension update rebuilds the bundle; same version is a no-op.
  const storage = context.globalStorageUri.fsPath;
  const gemDir = path.join(storage, "gems");
  const marker = path.join(storage, `installed-${version}`);
  if (fs.existsSync(marker) && fs.existsSync(gemDir)) {
    output.appendLine(`bundle: ${version} already installed at ${gemDir}`);
    return gemDir;
  }

  const ruby = findRuby();
  if (!ruby) {
    const msg = "mruby-lsp: no Ruby found to set up the bundled server. Set 'mrubyLsp.rubyPath' to your ruby executable.";
    output.appendLine(msg);
    vscode.window.showErrorMessage(msg);
    return undefined;
  }

  // Fresh dir for this version (drop any older bundle so we don't accumulate).
  try {
    fs.rmSync(gemDir, { recursive: true, force: true });
  } catch { /* first run: nothing to remove */ }
  fs.mkdirSync(gemDir, { recursive: true });

  const gems = fs.readdirSync(vendorDir).filter((f) => f.endsWith(".gem"));
  if (gems.length === 0) {
    output.appendLine(`bundle: vendor dir ${vendorDir} has no .gem files`);
    return undefined;
  }

  // gem install --local each vendored gem into gemDir (builds prism/value_bridge
  // native exts once here). --ignore-dependencies because every dep is vendored
  // and present; we install the full closure ourselves, no resolution/network.
  const env = bundleEnv(gemDir);
  const args = (g: string) => [
    "install", "--local", path.join(vendorDir, g),
    "--install-dir", gemDir, "--no-document", "--ignore-dependencies",
  ];

  output.appendLine(`bundle: installing ${gems.length} gems (v${version}) into ${gemDir} via ${ruby}`);
  const ok = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: "mruby-lsp: setting up language server (one-time after update)…" },
    async () => {
      for (const g of gems) {
        const r = await runGem(ruby, args(g), env);
        if (!r.ok) {
          output.appendLine(`bundle: install of ${g} failed:\n${r.out}`);
          vscode.window.showErrorMessage(`mruby-lsp: failed to set up the bundled server (${g}). See the mruby-lsp output for details.`);
          return false;
        }
        output.appendLine(`bundle: installed ${g}`);
      }
      return true;
    },
  );
  if (!ok) return undefined;

  // Stamp success: a marker file naming the version. Drop older markers.
  try {
    for (const f of fs.readdirSync(storage)) {
      if (f.startsWith("installed-") && f !== `installed-${version}`) {
        fs.rmSync(path.join(storage, f), { force: true });
      }
    }
  } catch { /* ignore */ }
  fs.writeFileSync(marker, version);
  output.appendLine(`bundle: ready, GEM_PATH=${gemDir}`);
  return gemDir;
}

// Run `gem` via the chosen ruby, capturing output. Uses `ruby -S gem` so we
// don't have to locate the gem binstub separately — ruby finds its own.
function runGem(ruby: string, args: string[], env: NodeJS.ProcessEnv): Promise<{ ok: boolean; out: string }> {
  return new Promise((resolve) => {
    const proc = cp.spawn(ruby, ["-S", "gem", ...args], { env });
    let out = "";
    proc.stdout.on("data", (d) => (out += d.toString()));
    proc.stderr.on("data", (d) => (out += d.toString()));
    proc.on("error", (e) => resolve({ ok: false, out: String(e) }));
    proc.on("close", (code) => resolve({ ok: code === 0, out }));
  });
}

// Path to an executable inside the installed bundle's bin dir.
// Locate mrdb (mruby's debugger). It MUST be the USER'S mrdb — the one built
// from their mruby checkout (the mruby-bin-debugger gem) — never one we ship:
// mrdb is tied to that exact mruby version + gem set, so a foreign mrdb can't
// run the program's bytecode. We never bundle mrdb. Order: explicit setting ->
// the mruby checkout the LSP already reflects (paths.env's mruby_root, where
// `rake` installs tools into bin/) -> the conventional <workspace>/mruby layout
// -> bare `mrdb` on PATH only as a last resort (and the setting can override).
function resolveMrdb(root?: string): string {
  const configured = vscode.workspace.getConfiguration("mrubyLsp").get<string>("mrdbPath");
  if (configured && configured.trim()) return configured.trim();

  const candidates: string[] = [];
  if (root) {
    // The exact mruby the server reflects, recorded at setup in paths.env.
    const mrubyRoot = pathsEnvValue(cacheDir(root), "mruby_root");
    if (mrubyRoot) {
      candidates.push(path.join(mrubyRoot, "bin", "mrdb"));
      candidates.push(path.join(mrubyRoot, "build", "host", "bin", "mrdb"));
    }
    // Conventional checkout location, even before the server cache exists.
    candidates.push(path.join(root, "mruby", "bin", "mrdb"));
    candidates.push(path.join(root, "mruby", "build", "host", "bin", "mrdb"));
  }
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return "mrdb";
}

function bundleBin(name: string): string | undefined {
  if (!bundlePath) return undefined;
  const exe = path.join(bundlePath, "bin", name);
  return fs.existsSync(exe) ? exe : undefined;
}

// Build the env for running FROM the bundle. GEM_HOME is the bundle (installs
// land there), but GEM_PATH must PREPEND the bundle to the existing path, not
// replace it: mruby's own build shells out to `rake` (and other system gems),
// and pointing GEM_PATH at only the bundle hides every system gem -> "can't
// find gem rake". Prepending keeps the bundle's gems visible AND the system's.
function bundleEnv(dir: string): NodeJS.ProcessEnv {
  const prior = process.env["GEM_PATH"];
  const gemPath = prior ? `${dir}${path.delimiter}${prior}` : dir;
  return { ...process.env, GEM_HOME: dir, GEM_PATH: gemPath };
}

// Shell-export form of bundleEnv, for sending into a terminal. POSIX sh.
function bundleEnvExport(dir: string): string {
  // $GEM_PATH expands in the running shell; if unset it yields empty, leaving a
  // trailing delimiter that gem tolerates. Quote the bundle (may contain spaces).
  return `export GEM_HOME=${JSON.stringify(dir)}; export GEM_PATH=${JSON.stringify(dir)}"${path.delimiter}$GEM_PATH"`;
}

// ── workspace detection: a workspace IS mruby iff it contains an mruby source
// checkout, identified by include/mruby.h — the mruby C API header, which exists
// ONLY in an mruby tree. This is true before any build, so we can offer to build
// an unbuilt project (the lock/reflect_so check below decides built-vs-offer).
async function isMrubyWorkspace(root: string): Promise<boolean> {
  const found = await vscode.workspace.findFiles(
    new vscode.RelativePattern(root, "**/include/mruby.h"),
    "**/node_modules/**",
    1,
  );
  return found.length > 0;
}

// ── locate the mruby-lsp binary. The gem's install hook recorded its exact
// install location at gem-install time in ~/.local/share/mruby-lsp/install.json
// (RubyGems knows the bindir then). We just read it — no PATH, no guessing.
// Order: install.json -> bare name (last resort).
function resolveServerCommand(): string {
  // Self-contained bundle first: the binstub inside our installed GEM_PATH.
  // This is the marketplace path — no global gem, no user PATH.
  const bundled = bundleBin("mruby-lsp");
  if (bundled) {
    output.appendLine(`server discovery: using bundled ${bundled}`);
    return bundled;
  }

  // The record lists every candidate bindir (user-install vs system differ);
  // first dir that actually holds the binstub wins. Legacy records have only
  // `bin`.
  const rec = installRecord();
  if (!rec) output.appendLine("server discovery: no install.json record");
  const candidates = rec?.bin_candidates ?? (rec?.bin ? [rec.bin] : []);
  for (const dir of candidates) {
    const exe = path.join(dir, "mruby-lsp");
    if (fs.existsSync(exe)) {
      output.appendLine(`server discovery: using ${exe}`);
      return exe;
    }
    output.appendLine(`server discovery: not found at ${exe}`);
  }
  output.appendLine("server discovery: falling back to bare 'mruby-lsp' on PATH");
  return "mruby-lsp"; // last resort: hope it's on PATH
}

// The gem install record, written by the install hook.
function installRecord(): { bin?: string; bin_candidates?: string[]; version?: string; ruby?: string } | undefined {
  try {
    // FIXED path: ENV-FREE home (passwd DB via os.userInfo), NOT
    // $XDG_DATA_HOME/$HOME — the same rule the install hook writes with and the
    // state store reads, so the record is always at the one dir env can't move.
    const f = path.join(homeDir(), ".local", "share", "mruby-lsp", "install.json");
    if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch (e) {
    output.appendLine(`install.json read error: ${String(e)}`);
  }
  return undefined;
}

// Locate mruby-lsp-setup the same way (bundle first, then next to the server).
function resolveSetupCommand(): string {
  const bundled = bundleBin("mruby-lsp-setup");
  if (bundled) return bundled;
  const server = resolveServerCommand();
  if (server !== "mruby-lsp" && server.endsWith("mruby-lsp")) {
    const setup = server.slice(0, -"mruby-lsp".length) + "mruby-lsp-setup";
    if (fs.existsSync(setup)) return setup;
  }
  return "mruby-lsp-setup";
}

// Read setup state from the user's OWN state store (~/.local/share/mruby-lsp/
// workspaces/<key>), keyed by the canonical workspace path — the SAME keying
// BuildDiscovery.state_dir uses in Ruby. NEVER read this from the workspace: a
// hostile repo could forge "set up" and make us trust an attacker cache.
// The user's home directory, resolved ENV-FREE via os.userInfo() (the passwd
// database on POSIX), NOT $HOME/$XDG. This MUST match BuildDiscovery.home_dir
// (Ruby's Etc.getpwuid) and the C launcher's getpwuid, so the extension, the
// server/setup, and the Landlock allow-list all agree on the work-root and the
// environment can't make them diverge. os.homedir() would honor $HOME, so we
// use userInfo().homedir, which reads the passwd entry directly.
function homeDir(): string {
  return os.userInfo().homedir;
}

function stateDir(root: string): string {
  // Passwd home + standard `.local/share` (NOT $XDG_DATA_HOME) — same env-free
  // trust-boundary reasoning as cacheDir / BuildDiscovery.state_dir.
  // MUST match Ruby's File.expand_path: absolute, normalized, but NOT
  // symlink-resolved. path.resolve does exactly that (realpath would diverge).
  const canonical = path.resolve(root);
  return path.join(homeDir(), ".local", "share", "mruby-lsp", "workspaces", slug(canonical));
}

// The build cache for a workspace: <home>/.cache/mruby-lsp/<slug>. Mirrors
// BuildDiscovery.cache_dir on the Ruby side (same passwd home, same slug), so
// the extension and the server/setup always agree on where a project's build
// artifacts live — and on the same tree the launcher allow-lists.
function cacheDir(root: string): string {
  return path.join(homeDir(), ".cache", "mruby-lsp", slug(path.resolve(root)));
}

// Read one `key=value` line from a cache's paths.env. Plain fixed-delimiter parse
// (paths.env is our own flat handoff file, not structured input); returns
// undefined if the file or key is absent.
function pathsEnvValue(cacheDirPath: string, key: string): string | undefined {
  let txt: string;
  try {
    txt = fs.readFileSync(path.join(cacheDirPath, "paths.env"), "utf8");
  } catch {
    return undefined;
  }
  for (const line of txt.split("\n")) {
    const eq = line.indexOf("=");
    if (eq > 0 && line.slice(0, eq) === key) return line.slice(eq + 1).trim();
  }
  return undefined;
}

// Flatten an absolute path into a single filesystem-safe directory name:
// /home/h/code/mruby-cbor -> home_h_code_mruby-cbor. NO hash — deterministic
// and readable. MUST stay byte-identical to path_slug in build_discovery.rb.
function slug(absPath: string): string {
  return absPath.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+/, "");
}

// "Set up" is not a stored claim but whether the build's FINAL artifact exists.
// A forced rebuild deletes the old build up front and writes the versioned
// reflect .so (then paths.env naming it) only once the whole build+compile
// succeeds — so the .so's presence means a FINISHED build, never one that merely
// started and was abandoned (libmruby.a, by contrast, appears mid-build and would
// lie). We take the path from paths.env and stat it. paths.env alone is not
// enough: it lives in the cache root and survives the wipe, so it can still name
// a .so the rebuild already deleted — the file must actually be there.
function isSetUp(root: string): boolean {
  const so = pathsEnvValue(cacheDir(root), "reflect_so");
  return so !== undefined && fs.existsSync(so);
}

// ── start the LSP client against our binary (offer-only build if not set up)
async function startClient(): Promise<void> {
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (!folder) return;
  const root = folder.uri.fsPath;

  if (!(await isMrubyWorkspace(root))) {
    output.appendLine("not an mruby workspace (no include/mruby.h) — idle");
    return;
  }

  // Is the project set up? This is NOT a workspace claim: isSetUp() reads the
  // build's final artifact path from the OUT-OF-WORKSPACE cache
  // (<home>/.cache/mruby-lsp/<slug>/paths.env) and stats the reflect .so. A
  // cloned/hostile repo therefore cannot forge "set up" — nothing in the
  // workspace decides it.
  if (!isSetUp(root)) {
    // Offer-only: never build automatically.
    const pick = await vscode.window.showInformationMessage(
      "mruby-lsp: this project isn't set up yet. Build the language server now?",
      "Build",
      "Not now",
    );
    if (pick === "Build") {
      await runSetup(root);
    }
    return;
  }

  const command = resolveServerCommand();

  // When running from the vendored bundle, the server must resolve its gems
  // (prism, language_server-protocol, value_bridge) from the bundle's GEM_PATH —
  // the user has nothing installed globally. Set it for both run and debug.
  const serverEnv: NodeJS.ProcessEnv = bundlePath ? bundleEnv(bundlePath) : { ...process.env };

  // No argv to the server: the workspace comes from the LSP `initialize`
  // (workspaceFolders/rootUri) — the only source the spec defines, and the same
  // one every other client (Helix, Neovim, …) uses — and the launcher's stage-1
  // wall is workspace-independent. We still set cwd to the project (conventional;
  // the server also falls back to cwd if a client sent no rootUri).
  const serverOptions: ServerOptions = {
    run: { command, options: { cwd: root, env: serverEnv } },
    debug: { command, options: { cwd: root, env: serverEnv } },
  };
  // Read user settings to forward to the server at initialize. requestTimeout
  // is per-workspace so a project with a big binary (slow first addr2line) can
  // raise it without affecting others.
  const cfg = vscode.workspace.getConfiguration("mrubyLsp", folder?.uri);
  const requestTimeoutSeconds = cfg.get<number>("requestTimeout", 15);
  // One switch controls both sides: when tracing is on, the client logs all
  // JSON-RPC to the output channel AND the server logs its per-request
  // lifecycle (gated on this env var). Off by default — silent normal runs.
  const traceServer = cfg.get<string>("trace.server", "off");
  if (traceServer !== "off") serverEnv.MRUBY_LSP_TRACE = "1";

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "ruby" }],
    workspaceFolder: folder,
    outputChannel: output,
    // All JSON-RPC traffic (every request/response/notification, with params and
    // timing) goes to the SAME output channel as server stderr, so the full
    // client<->server conversation is visible in one place for debugging.
    traceOutputChannel: output,
    revealOutputChannelOn: RevealOutputChannelOn.Never,
    initializationOptions: {
      requestTimeoutSeconds,
    },
  };

  client = new LanguageClient("mrubyLsp", "mruby Language Server", serverOptions, clientOptions);
  try {
    await client.start();
    output.appendLine(`server started: ${command} ${root}`);
  } catch (e) {
    client = undefined;
    const msg = `mruby-lsp: failed to start server — ${String(e)}`;
    output.appendLine(msg);
    vscode.window.showErrorMessage(msg);
  }
}

async function stopClient(): Promise<void> {
  if (client) {
    try {
      await client.stop();
    } catch (e) {
      output.appendLine(`stop error: ${String(e)}`);
    }
    client = undefined;
  }
}

// ── run mruby-lsp-setup in a terminal (the human-gesture build)
// Is the mruby-lsp gem installed (did its install hook record install.json,
// and does the recorded binary exist)?
function gemInstalled(): boolean {
  // The bundled server counts as installed (it's in our GEM_PATH). Otherwise
  // the install record names the bindir; the gem is installed iff the runnable
  // is there. (resolveServerCommand returns the absolute path when found.)
  return bundleBin("mruby-lsp") !== undefined || resolveServerCommand() !== "mruby-lsp";
}

// Install the mruby-lsp gem for the user, WITHOUT touching their project and
// WITHOUT asking. --user-install puts it in the user's gem dir (not the project
// bundle, no Gemfile change). Resolves when the install process exits.
function bootstrapGem(): Promise<boolean> {
  // We are not on rubygems.org yet, and the gem is installed from source via
  // `rake install`. So we don't silently try `gem install` (it just fails with a
  // confusing "not found"). Tell the user the exact command instead.
  const msg =
    "mruby-lsp: the server gem isn't installed. Install it from the project source: `rake install`.";
  output.appendLine(msg);
  vscode.window.showErrorMessage(msg);
  return Promise.resolve(false);
}

// Run mruby-lsp-setup non-interactively (no terminal) for an already-set-up
// workspace. Safe to run headless ONLY because a set-up workspace has a saved
// config choice, so discovery resolves without the ambiguous-config prompt.
// Returns true on success. Used for the silent post-update rebuild: the native
// fingerprint inside setup decides whether anything actually recompiles, so a
// no-native-change update makes this a fast no-op.
function runSetupHeadless(root: string): Promise<boolean> {
  const setup = resolveSetupCommand();
  // `setup` is the mruby-lsp-setup LAUNCHER — a compiled executable since the
  // sandbox MVP, not a ruby script. Invoke it directly: it re-execs the Ruby
  // impl itself, and running it through `ruby` would parse the ELF binary
  // ("Invalid char '\x7F'"). The terminal paths already spawn it directly.
  const env = bundlePath ? bundleEnv(bundlePath) : process.env;
  return new Promise((resolve) => {
    const proc = cp.spawn(setup, [root], { env });
    let out = "";
    proc.stdout.on("data", (d) => (out += d.toString()));
    proc.stderr.on("data", (d) => (out += d.toString()));
    proc.on("error", (e) => { output.appendLine(`post-update setup error: ${String(e)}`); resolve(false); });
    proc.on("close", (code) => {
      output.appendLine(`post-update setup (${root}) exit ${code}:\n${out}`);
      resolve(code === 0);
    });
  });
}

// Every workspace with a FINISHED build: one cache dir per workspace slug; read
// each paths.env and keep those whose reflect .so still exists on disk (and whose
// project dir is still present). Derived from the build itself — a wiped or
// half-finished cache simply isn't listed, so there is no stored "done" flag to
// go stale. The cache lives outside any workspace (<home>/.cache/mruby-lsp,
// passwd-home based like cacheDir — keyed by the project's absolute-path slug),
// so a cloned repo cannot forge an entry.
function consentedWorkspaces(): { root: string }[] {
  const dir = path.join(homeDir(), ".cache", "mruby-lsp");
  const out: { root: string }[] = [];
  let entries: string[];
  try {
    entries = fs.readdirSync(dir);
  } catch {
    return out; // no cache yet
  }
  for (const s of entries) {
    const cd = path.join(dir, s);
    const project = pathsEnvValue(cd, "project");
    const so = pathsEnvValue(cd, "reflect_so");
    if (project && so && fs.existsSync(so) && fs.existsSync(project)) {
      out.push({ root: project });
    }
  }
  return out;
}

// After an extension update OR a fresh extension instance that finds an existing
// build (the dev `rake vscode:install` reinstall, whose globalState is wiped),
// run setup ONCE in every consented workspace. Setup is idempotent and cheap
// when nothing changed (it restores mtimes and the in-setup native fingerprint
// no-ops the compile), and it actually REBUILDS only when the native code differs
// from what that workspace was last built against. So this is "setup everywhere
// once per version change; rebuild where native changed." The new version is
// recorded before sweeping, so it runs at most once per (re)install.
async function maybeRebuildAfterUpdate(context: vscode.ExtensionContext): Promise<void> {
  const current = context.extension.packageJSON.version as string;
  const last = context.globalState.get<string>("lastVersion");
  if (last === current) return;             // same version already handled — nothing to do
  await context.globalState.update("lastVersion", current);

  // No early-out on `last === undefined`. A wiped globalState (a genuine first
  // install OR the dev `rake vscode:install`, which uninstalls first) looks the
  // same — but if a consented workspace already has a build, that build may
  // predate this extension instance and must be re-validated. The ABSENCE of
  // state is itself the marker to re-run setup. consentedWorkspaces() is the
  // real gate: empty on a true first install (no build), non-empty when a build
  // survived in XDG (which uninstall never touches).
  const roots = consentedWorkspaces().map((w) => w.root);
  if (roots.length === 0) return;

  const reason = last === undefined ? `fresh instance on v${current}` : `update ${last} -> ${current}`;
  output.appendLine(`${reason}: running setup in ${roots.length} workspace(s)`);
  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: "mruby-lsp: refreshing builds after update…" },
    async () => {
      // Sequential: a parallel sweep would launch several mruby builds at once.
      // Each setup rebuilds only if its native fingerprint changed.
      for (const root of roots) {
        await runSetupHeadless(root);
      }
    },
  );
}

async function runSetup(root: string): Promise<void> {
  if (!gemInstalled()) {
    const ok = await bootstrapGem();
    if (!ok) return;
  }
  const setup = resolveSetupCommand();
  const term = vscode.window.createTerminal("mruby-lsp setup");
  term.show();
  // When running from the vendored bundle, the setup command (and the reflect
  // build it drives) must see the bundle's gems. Export GEM_PATH into the
  // terminal before invoking. Quoted, POSIX-shell form.
  if (bundlePath) {
    term.sendText(bundleEnvExport(bundlePath));
  }
  term.sendText(`${JSON.stringify(setup)} ${JSON.stringify(root)}`);
  vscode.window.showInformationMessage(
    "mruby-lsp: building in the terminal. Run 'mruby-lsp: Restart Server' when it finishes.",
  );
}

// Run an update action ("mruby" | "gems") via mruby-lsp-update, in a terminal.
// Each update re-runs setup itself, so the server just needs a restart after.
function runUpdate(action: "mruby" | "gems", root: string): void {
  const setup = resolveSetupCommand();
  // mruby-lsp-update sits next to mruby-lsp-setup.
  const update =
    setup.endsWith("mruby-lsp-setup")
      ? setup.slice(0, -"mruby-lsp-setup".length) + "mruby-lsp-update"
      : "mruby-lsp-update";
  const term = vscode.window.createTerminal(`mruby-lsp update ${action}`);
  term.show();
  if (bundlePath) {
    term.sendText(bundleEnvExport(bundlePath));
  }
  term.sendText(`${JSON.stringify(update)} ${action} ${JSON.stringify(root)}`);
  vscode.window.showInformationMessage(
    `mruby-lsp: updating ${action} in the terminal. Run 'mruby-lsp: Restart Server' when it finishes.`,
  );
}

export function activate(context: vscode.ExtensionContext): void {
  output = vscode.window.createOutputChannel("mruby-lsp");
  context.subscriptions.push(output);

  // Field diagnosis: desktop-launched editors can carry a different env than
  // the user's shell; print what THIS process actually sees.
  output.appendLine(`activate v${context.extension.packageJSON.version}`);
  output.appendLine(`env HOME=${process.env["HOME"] ?? "(unset)"} XDG_DATA_HOME=${process.env["XDG_DATA_HOME"] ?? "(unset)"} PATH=${(process.env["PATH"] ?? "").split(":").slice(0, 4).join(":")}...`);

  // Every declared command is registered here (no declared-but-unregistered drift).
  context.subscriptions.push(
    vscode.commands.registerCommand("mrubyLsp.build", () => {
      const folder = vscode.workspace.workspaceFolders?.[0];
      if (folder) runSetup(folder.uri.fsPath);
    }),
    vscode.commands.registerCommand("mrubyLsp.rebuild", () => {
      const folder = vscode.workspace.workspaceFolders?.[0];
      if (folder) runSetup(folder.uri.fsPath);
    }),
    vscode.commands.registerCommand("mrubyLsp.restart", async () => {
      await stopClient();
      await startClient();
    }),
    vscode.commands.registerCommand("mrubyLsp.stop", async () => {
      await stopClient();
    }),
    vscode.commands.registerCommand("mrubyLsp.updateMruby", () => {
      const folder = vscode.workspace.workspaceFolders?.[0];
      if (folder) runUpdate("mruby", folder.uri.fsPath);
    }),
    vscode.commands.registerCommand("mrubyLsp.updateGems", () => {
      const folder = vscode.workspace.workspaceFolders?.[0];
      if (folder) runUpdate("gems", folder.uri.fsPath);
    }),
  );

  // ── Debugger (mrdb over DAP) ──────────────────────────────────────────────
  // Registration is inert until the user starts a debug session; the adapter
  // (built on the official @vscode/debugadapter) drives the USER'S mrdb via
  // mrdbDriver. There is NO canonical mruby entry point, so on F5 we ASK which
  // .rb/.mrb to run (the file IS the entry — it may call a top-level main, be a
  // test runner, start a method from another gem, …; we assume nothing). mrdb is
  // located from the user's own mruby build (never bundled — it must match their
  // VM); a missing mrdb now surfaces a real error instead of hanging.
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("mruby", {
      async resolveDebugConfiguration(folder, config) {
        // F5 with no launch.json: make this a launch session.
        if (!config.type && !config.request && !config.name) {
          config.type = "mruby";
          config.request = "launch";
          config.name = "mruby: debug";
        }
        // ASK which file to run when none is pinned (mruby has no canonical
        // entry — the user picks the .rb/.mrb that starts their program). The
        // active editor seeds the dialog; cancelling aborts the launch.
        if (config.request === "launch" && !config.program) {
          const active = vscode.window.activeTextEditor?.document.uri;
          const picked = await vscode.window.showOpenDialog({
            canSelectMany: false,
            openLabel: "Debug this mruby file",
            filters: { mruby: ["rb", "mrb"] },
            defaultUri: active,
          });
          if (!picked || picked.length === 0) return undefined; // cancelled
          config.program = picked[0].fsPath;
        }
        if (!config.program) return undefined;
        // Fill the mrdb path (setting -> mruby build -> PATH) unless pinned.
        const root = folder?.uri.fsPath ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
        if (!config.mrdb) config.mrdb = resolveMrdb(root);
        // Trace + stopOnEntry from settings when the launch config doesn't pin
        // them — so both work without writing a launch.json.
        const cfg = vscode.workspace.getConfiguration("mrubyLsp");
        if (config.trace === undefined) {
          config.trace = cfg.get<boolean>("debugTrace") === true;
        }
        if (config.stopOnEntry === undefined) {
          config.stopOnEntry = cfg.get<boolean>("debugStopOnEntry") !== false; // default on
        }
        return config;
      },
    }),
    vscode.debug.registerDebugAdapterDescriptorFactory("mruby", {
      createDebugAdapterDescriptor() {
        // Lazy-require so non-debugging sessions never load the adapter library.
        // Path is relative to the COMPILED file (out/extension.js -> ../debug/).
        // eslint-disable-next-line @typescript-eslint/no-var-requires
        const { MrdbDebugSession } = require("../debug/mrdbDebugSession");
        return new vscode.DebugAdapterInlineImplementation(new MrdbDebugSession());
      },
    }),
  );

  // While debugging, tell VS Code WHICH expression to evaluate when the user
  // hovers the source. Without this, VS Code uses a word-pattern heuristic with
  // no language knowledge — hovering inside "hello world" sends the fragment
  // `"hello` to mrdb (unterminated string). The server resolves the real
  // expression bounds with Prism (a hover anywhere in a string literal -> the
  // whole literal; on a variable/const/ivar -> that name; on a call with args
  // or a keyword -> nothing). VS Code only invokes this during a debug session.
  context.subscriptions.push(
    vscode.languages.registerEvaluatableExpressionProvider(
      { language: "ruby" },
      {
        async provideEvaluatableExpression(document, position, token) {
          if (!client) return undefined;
          try {
            const res = await client.sendRequest<{
              range: { start: { line: number; character: number }; end: { line: number; character: number } };
              expression: string;
            } | null>(
              "mrubyLsp/evaluatableExpression",
              {
                textDocument: { uri: document.uri.toString() },
                position: { line: position.line, character: position.character },
              },
              token,
            );
            if (!res || !res.range) return undefined;
            const r = res.range;
            const range = new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character);
            return new vscode.EvaluatableExpression(range, res.expression);
          } catch {
            // Server down / request unsupported: fall back to VS Code's default.
            return undefined;
          }
        },
      },
    ),
  );

  // Activation startup: install the vendored bundle (once per version), refresh
  // the build after an extension update, then run the client against it. A
  // marketplace user has nothing installed globally — the bundle IS the server.
  // Failure to install surfaces; startClient then falls back to global discovery
  // (dev checkout) or reports the gem is missing.
  const startupSequence = async () => {
    try {
      bundlePath = await ensureBundle(context);
    } catch (e) {
      output.appendLine(`bundle setup error: ${String(e)}`);
    }
    // After the bundle is in place, if THIS is an extension update, refresh the
    // open set-up workspace's build (the in-setup native fingerprint decides if
    // anything actually recompiles). Must precede startClient so the server
    // launches against the refreshed cache. This update pass is MANDATORY — a
    // version-skewed build leaves the server unable to load — so it runs on every
    // (trusted) activation after a version change.
    try {
      await maybeRebuildAfterUpdate(context);
    } catch (e) {
      output.appendLine(`post-update rebuild error: ${String(e)}`);
    }
    await startClient();
  };
  const runStartup = () =>
    void startupSequence().catch((e) => {
      output.appendLine(`activation error: ${String(e)}`);
      vscode.window.showErrorMessage(`mruby-lsp: activation failed — ${String(e)}`);
    });

  // GATE ON WORKSPACE TRUST. Everything in startupSequence installs gems, runs
  // the project's mruby build, or launches the server against the workspace, so
  // none of it may run automatically in an untrusted workspace. VS Code's trust
  // prompt is the gate (it also replaces our own "Build?" question, which lives
  // downstream in startClient). In an untrusted workspace the extension stays
  // idle — commands remain registered — and the deferred startup fires the moment
  // the user grants trust.
  if (vscode.workspace.isTrusted) {
    runStartup();
  } else {
    output.appendLine(
      "workspace is not trusted — deferring gem bundle install, build refresh, and server start until trust is granted",
    );
    const trustSub = vscode.workspace.onDidGrantWorkspaceTrust(() => {
      trustSub.dispose();
      output.appendLine("workspace trust granted — running deferred startup");
      runStartup();
    });
    context.subscriptions.push(trustSub);
  }
}

export async function deactivate(): Promise<void> {
  await stopClient();
}
