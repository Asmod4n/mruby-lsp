# Sandbox + born-confined launcher (cross-platform design)

Status: Linux Iteration 1 BUILT (Landlock FS floor + env-scrub + fd-hygiene +
PR_SET_NO_NEW_PRIVS, mandatory, in ext/mruby_lsp_launcher/launcher.c, installed
by the gem at install time as `mruby-lsp` itself). Iteration 2 (seccomp syscall
floor + only-kill-own-children) deferred — it needs allow-set tuning against a
real run. macOS and Windows are speced to the right primitives
but NOT built or verified.
This document is written fresh against the current architecture (live-VM
reflection as source of truth, `*.rb.lock` as the pinned entry point, C as a
dumb FFI bridge, no eval outside the debugger). It takes the older `notepad`
repo's sandbox/consent notes as INSPIRATION only — none of it is transplanted.

Two independent gates, never conflated:
- CONSENT gates WHETHER we build/run project code at all (see CONSENT-LAYER).
- SANDBOX gates WHAT the running server may do once started (this document).
Both are required; neither replaces the other.

---

## 0. Non-negotiable: no added attack surface

We do NOT introduce a long-lived broker/daemon, a privileged helper, a setuid
binary, or an IPC channel. Any of those is a new thing on the user's machine to
exploit or escalate through — the opposite of the goal. The server runs as the
ordinary user who launched the editor and confines ITSELF, then disappears into
the confined image.

Mechanism: **self-exec (re-exec) prelude**, not a spawning broker.

    launcher prelude (same user, no extra privilege)
      -> install what survives exec (seccomp filter) + prepare paths
      -> scrub injection vectors (LD_*, DYLD_*, stray fds)
      -> execve() the real server image
         => the new image's main()/constructors start ALREADY confined

No resident process remains. The "launcher" is a thin front of the same process
lineage, gone after exec. Nothing new persists to be attacked.

---

## 1. The born-confined ordering guarantee (why a prelude, not main())

Self-confinement inside `main()` is too late. Anything that runs BEFORE main has
full rights: ELF `.init_array` constructors, `LD_PRELOAD`/`DYLD_INSERT_LIBRARIES`
shims, static C++ ctors in a linked gem (e.g. a C++ runtime), a malicious DLL's
`DllMain` on Windows. Earlier work named this "Test A": a pre-main constructor
beats any in-main lockdown. Verified on Linux by defeating exactly that attack.

The fix is ordering: confinement must be imposed on the image BEFORE its own code
runs. Two ways to get there without a daemon:

1. Carry-across-exec (Linux): a seccomp filter installed in the prelude SURVIVES
   `execve`. Install filter -> exec server -> server is born filtered. The
   prelude also scrubs `LD_PRELOAD` so no shim loads into the new image.
2. Kernel-at-creation (macOS/Windows): the OS applies confinement when it creates
   the process image — macOS via a code-signed entitlement, Windows via the token
   supplied at `CreateProcess`. The confinement predates the image's constructors
   by construction.

Landlock is a partial exception: its restriction is installed in the prelude and,
like seccomp, the restriction persists across exec and is inherited — so the FS
floor is also born-confined. (Landlock rules apply to the thread/process and are
preserved across execve.)

---

## 2. Need-set (what the confined server legitimately requires)

Derived from the current architecture, not the old one:
- READ: the workspace `@root`, the `*.rb.lock` and build config, the compiled
  reflection image + its build dir, the toolchain (mrbc and friends), and — the
  load-bearing detail — the DYNAMIC LINKER and every shared library the server
  and mrbc dlopen/transitively need. Missing a linker/lib path makes mrbc spawn
  or server startup fail cryptically. Enumerate via ldd at build, not by guessing.
- READ+WRITE: a single temp/cache area (the XDG-cache build dir) and stdio.
- EXEC: mrbc / the build toolchain (only during a consented build).
- DENY: network (no socket), writes anywhere outside the workspace/temp, reads of
  unrelated user data (~/.ssh, browser profiles, etc.).

After lockdown for the steady-state (request-serving, not building) the server
holds exactly stdio fds and needs no further `open` and no `socket`.

### 2a. The fetch/build air-gap (privilege separation)

Two capabilities must never sit in the same process: **network** (only the
fetch step contacts remote repos) and **executing fetched code** (only the
build step runs Rakefiles/gcc/mrbgem hooks on cloned sources). Separate them and
make their writable areas disjoint, and a compromised fetch can't plant into the
tree the build trusts, while a compromised build can't phone home.

Slice 1 (DONE) is the disjoint FS, under the per-workspace cache root:
- `fetch/repos/<name>` — gem CLONES; network writes here (gem_clone_dir, set in
  the wrapper from `MRUBY_LSP_FETCH_DIR` before the user-config replay).
- `build/<name>` — built artifacts; offline, never the fetch tree.

Slice 1b (DONE) makes the work-root ENV-FREE: cache + state roots derive from
the passwd database (Ruby `Etc.getpwuid(Process.uid).dir`, TS
`os.userInfo().homedir` — NOT `os.homedir()`, which honors `$HOME`), the same
source the launcher's `getpwuid(getuid())` Landlock allow-list already uses. So
env can't relocate the work-root or make the three sides disagree. Layout is
the conventional `<home>/.cache/mruby-lsp` + `<home>/.local/share/mruby-lsp`
(kept separate rather than consolidated — both are env-free and both are in the
launcher's RW allow-list, which is what the trust boundary needs).

Slice 2 (DONE) is the PHASE split with a network seal on the build:
- PHASE 1 `rake fetch` (network ALLOWED) — cloning is a side-effect of the
  config eval at Rakefile load (`gem` → `fetch!` runs before any task), so
  `rake fetch` pulls every declared gem + deps into `fetch/` without building.
- PHASE 2 `mruby-lsp-nonet rake` (network DENIED) — a seccomp-BPF filter
  (ext/mruby_lsp_launcher/no_network.h) fails AF_INET/AF_INET6 `socket()` with
  EACCES while leaving AF_UNIX/pipes/file I/O intact; fetched build code can't
  phone home. Re-eval re-runs the gem calls but `git_clone_dependency` returns
  early when `.git` exists → zero network. The filter covers x86_64/aarch64 and
  KILLs foreign-arch syscalls (no i386/x32 compat bypass), and it is FAIL-CLOSED:
  the wrapper refuses to exec the build unsealed, and `install_no_network_seccomp`
  reports a distinct "unsealable" code (never a silent success) on an unhardcoded
  arch / missing headers. When the seal can't engage on Linux, setup does NOT
  build unsealed silently — it gets explicit consent (tty prompt, or the editor's
  dialog via the `MRUBY_LSP_NET_SEAL_UNAVAILABLE` sentinel + a re-invoke with
  `--consent-no-network-seal`), mirroring the Landlock FS-wall consent. Non-Linux
  has no such primitive and builds as before. The SERVER role is intentionally
  NOT sealed — an inherited
  filter would block the fetches its own rebuild-spawn (the `setup` role,
  `lib/mruby_lsp/setup.rb`) must do when a gem is added.

Pending: the FS wall extended to the setup/update launcher roles (today
`fs_wall=0`) — needs a bounded work-root + mruby_root in the allow-list.

---

## 3. Linux (CONCRETE — build first)

Floor = seccomp-bpf; second wall = Landlock; both born-confined.

### Two-stage Landlock (the workspace is only knowable from `initialize`)

The FS wall is split across the launcher and the server, because the workspace
root is NOT known when the launcher runs. The only spec-portable source of the
workspace is the LSP `initialize` request (`workspaceFolders`/`rootUri`) — argv
and cwd are out of the LSP spec and editor-specific (Helix passes no argv at all)
— and `initialize` arrives only AFTER the server is up. Landlock layers can only
ever TIGHTEN (they AND-combine), so a read rule set chosen by the launcher could
never be widened to include the workspace later. Therefore:

- **Stage 1 — launcher, before Ruby** (`ext/mruby_lsp_launcher/launcher.c`):
  confine WRITES + EXEC only. Reads stay OPEN. Writes are allowed only on the
  build cache / state dir / tmp / safe `/dev` nodes; exec only on the toolchain,
  Ruby, version-manager dirs, and the gem root. Then the seccomp MARKER, then
  `execve` Ruby on the CLI dispatcher. The pre-stage-2 window runs only trusted
  code (our gem + prism/rdoc); `reflect.so` is loaded only after stage 2 is up.
- **Stage 2 — server, after `initialize`** (`ext/mruby_lsp_landlock`, a tiny
  CRuby ext exposing `MrubyLsp::Landlock.restrict_reads`): once `@workspace` is
  resolved from `initialize`, stack a layer handling `READ_FILE|READ_DIR` that
  grants reads only beneath the project (`@workspace` + mruby_root + build cache),
  our state dirs, the Ruby prefix, and every `Gem.path` — plus the system/Ruby
  base baked into the ext. Every read outside that union is then denied, for this
  process and the rebuild child it spawns. If the kernel headers don't name
  Landlock the ext compiles to a stub that defines nothing, so the server learns
  "no stage-2 wall here" from `defined?(MrubyLsp::Landlock)` and degrades.

### Prelude sequence (the re-exec front)
1. fd hygiene: close everything except 0/1/2 and any pipe actually used. seccomp
   permits read/write on ANY inherited fd, so leaked fds are a hole — scrub them.
2. Scrub injection env: unset `LD_PRELOAD`, `LD_AUDIT`, `LD_LIBRARY_PATH`, so no
   shim loads into the post-exec image.
3. `PR_SET_NO_NEW_PRIVS` — precondition for unprivileged seccomp.
4. Stage-1 Landlock (if ABI present): create a ruleset handling the WRITE/EXEC
   access bits (NOT reads — see above), grant write on cache/state/tmp + exec on
   toolchain/Ruby/gem-root; `landlock_restrict_self`. Query ABI with
   `landlock_create_ruleset(NULL,0,LANDLOCK_CREATE_RULESET_VERSION)`; apply only
   the access bits the running ABI defines. Syscalls 444/445/446.
5. seccomp-bpf: an allow-all filter as the "confined" MARKER (the server reads
   `/proc/self/status` `Seccomp:` to learn, env/arg-free, that stage 1 is up).
   Survives the exec; children inherit it. The real net seal stays in
   `mruby-lsp-nonet` around the offline build phase.
6. `execve` Ruby on the CLI dispatcher. It starts born-confined (writes/exec);
   the server raises the stage-2 read wall right after `initialize`.

### Graceful degradation (MANDATORY — never fail-closed on startup)
A sandbox bug that blocks something the server needs is baffling to debug and
locks the user out. So: if Landlock is unavailable (e.g. kernel `ENOSYS` — this
literally happened in the dev sandbox), no-op that wall and continue. If the
seccomp floor itself cannot be installed, the policy choice is explicit and
logged, defaulting to "run unconfined with a visible warning" rather than
refuse-to-start — because an LSP that won't start is worse UX than one that warns.
(Consent layer already gated whether we got here at all.)

### "Only kill our own children" (separable phase 2)
Goal: the server can signal only the build children it owns, nothing else.
- Phase 1 (done in prior work): hold a `pidfd` for each spawned child; reap via
  `pidfd` + timeout. No pid-racing.
- Phase 2 (heavier, build standalone): seccomp-deny `kill`/`tkill`/`tgkill`,
  ALLOW `pidfd_send_signal` — so the only way to signal anything is through a
  pidfd the server legitimately holds. Higher fail-closed risk; ship after the
  FS floor is solid.

### Children inherit
Once the server is Landlock-restricted and seccomp-filtered, a spawned `mrbc`
inherits both. We do NOT separately sandbox mrbc; confining the parent confines
the child. This is why enumerating the linker/lib paths matters — mrbc needs them
too.

---

## 4. macOS (SPEC — not built)

No Landlock/seccomp. The born-confined property comes from the OS at image
creation, via the App Sandbox, plus env scrub for the injection vector.

- Primary: a **code-signed** server binary carrying an App Sandbox entitlement
  with a tight profile — `file-read*` limited to workspace + toolchain + libs,
  `file-write*` limited to the cache/temp dir, `network*` denied, `process-exec`
  limited to mrbc. Because the entitlement is applied by the kernel when the
  signed image is created, confinement predates the image's constructors — the
  born-confined guarantee holds WITHOUT a daemon. This is the path to match Linux.
- Fallback (weaker): `sandbox_init(3)` with a Seatbelt profile called as the very
  first thing in `main`. This has the "Test A" window — a pre-main constructor
  runs unconfined — so it is strictly weaker and only a degradation, not the
  target.
- Injection scrub: unset `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`,
  `DYLD_FRAMEWORK_PATH` before any exec; prefer a signed binary (dyld ignores
  insertions into signed processes lacking the get-task-allow / disable-library-
  validation entitlements — keep those OFF).
- Children: a process spawned from a sandboxed parent inherits the sandbox; mrbc
  is confined for free, same as Linux.
- Packaging cost (surfaces only when actually built): code signing + entitlement
  plist + notarization for distribution. Treat as real work, unverified here.

No long-lived helper. The "launcher" is still just the signed image starting
confined; env scrub happens in the thin prelude before exec.

---

## 5. Windows (SPEC — not built)

No Landlock/seccomp; the model is capability/ACL-shaped, and the born-confined
property comes from the TOKEN supplied at process creation. This is the one place
a *parent* sets confinement on a *child* image — but it is still NOT a resident
broker: the parent is the same launcher lineage, it creates the confined image
and exits, nothing persists.

- Primary: create the server process with a **restricted token** or an
  **AppContainer** profile via `CreateProcess`/`CreateProcessAsUser` with the
  confined token + a **Job object** (limits: no child processes beyond mrbc, no
  network if using AppContainer capability denial, memory/handle caps). Because
  the token is applied at creation, the image is born confined before its DLLs'
  `DllMain` runs. WFP / not granting the network capability denies sockets.
- Block injected code: set the process mitigation policy to block non-Microsoft
  (or non-signed) DLL loads, closing the DLL-injection / `DllMain` constructor
  vector — the Windows analogue of `LD_PRELOAD` scrub.
- Filesystem deny: a token with no access to the user profile; grant only
  workspace (read), toolchain/libs (read+exec), cache/temp (read+write) via ACLs
  / AppContainer profile.
- Honest gap: AppContainer's capability model is coarser than seccomp's syscall
  allow-list — you grant/deny capabilities and securable-object access, not
  individual syscalls. "Minimal syscall set" is not the Windows model; "minimal
  capability + restricted token + Job limits" is. Match the SECURITY GOAL (no
  net, no FS outside workspace, no injection, can't kill unrelated processes),
  not the mechanism.
- Children: mrbc is launched into the same Job / token, inheriting the limits.

Packaging cost: a small launcher that does token-at-CreateProcess + Job + DLL
mitigation. Unverified here.

---

## 6. Cross-platform shape (the invariant, mechanisms differ)

| Property              | Linux                         | macOS                          | Windows                                  |
|-----------------------|-------------------------------|--------------------------------|------------------------------------------|
| Confine mechanism     | seccomp-bpf + Landlock        | App Sandbox (entitlement)      | restricted/AppContainer token + Job      |
| Born-confined via     | filter survives execve        | kernel applies entitlement     | token applied at CreateProcess           |
| Block injected code   | scrub LD_*, close fds         | scrub DYLD_*, signed image     | block non-MS DLLs (mitigation policy)    |
| Filesystem deny       | Landlock / seccomp no-open    | profile file-read*/write* deny | token with no FS access + ACLs           |
| Network deny          | seccomp no-socket             | profile network* deny          | no network capability + WFP              |
| Only-kill-own-children| pidfd + seccomp deny kill     | sandbox + pid-kill fallback    | Job object owns the children             |
| Daemon / extra surface| NONE (re-exec prelude)        | NONE (signed image)            | NONE (launcher exits after CreateProcess)|

The UNIFYING PRINCIPLE that must hold on all three, even though the per-OS
backend differs: **confinement is imposed on the worker before the worker's own
code runs — by the carry-across-exec prelude (Linux), by the kernel at image
creation (macOS entitlement / Windows token).** Self-confinement in `main` is the
weaker "Test A" fallback everywhere and must never be the primary path. And on no
platform do we add a long-lived helper or any new privileged surface.

---

## 7. Build order

1. Linux Landlock FS floor in the re-exec prelude (highest value, self-contained,
   degrade-gracefully). Proven shape from prior work; rebuild fresh here.
2. Linux seccomp syscall floor (careful: fail-closed risk; tune the allow-set
   against a real build+reflect run, the missing-syscall failure is cryptic).
3. Linux phase-2 "only kill own children" (seccomp deny kill / allow
   pidfd_send_signal).
4. macOS signed-entitlement path; then Windows token+Job+DLL-mitigation. Each
   degrades gracefully where a mechanism is absent. Each has packaging work that
   only surfaces when actually built — treat Linux as the proven reference and
   these as speced-credible-but-unverified until built on real hardware.

## 8. What is explicitly NOT claimed
- macOS and Windows here are DESIGN, not implementation. No Swift/Win32 code is
  shipped pretending to work.
- Even the Linux seccomp allow-set must be tuned against a real run; the dev
  sandbox lacked Landlock (`ENOSYS`), so only the degradation path — not the full
  Landlock wall — was exercisable in-sandbox. Verify on the target machine.
