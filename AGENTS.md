# AGENTS.md

Orientation for any agent (or human) picking up this repo. Read this first, then
the docs it points to. This file is deliberately stable: it does **not** record
the current state of the project — that lives in the docs below and would rot
here. Keep this file about *how to work*, not *where things stand*.

## Start here, in this order

1. `README.md` — user-facing: what mruby-lsp is, install, project setup,
   debugging, limitations.
2. `CONTRIBUTING.md` — how to build, test, and work in this repo.
3. `docs/GOTCHAS.md` — hard-won pitfalls. Read before touching native/build code;
   most non-obvious failures are already documented here.
4. The **GitHub issue tracker** — current state, open work, and roadmap. (Project
   state and tasks live in issues, not in tree-checked dev logs.)

Reference docs, read when relevant: `docs/CONFORMANCE.md` (the conformance
suite's contract), `CHANGELOG.md` (release history), `docs/design/`
(cross-platform / sandbox design).

## Keep the docs current — this is mandatory

The docs are the project's memory. An agent that changes behavior without
updating them blinds the next one. After any change that alters state, update the
matching place **in the same session, before considering the work done**:

| You changed… | Update… |
|---|---|
| Project state / what comes next | the relevant **GitHub issue** |
| A user-visible release-worthy change | `CHANGELOG.md` |
| Discovered a non-obvious failure / footgun | `docs/GOTCHAS.md` |
| Conformance-suite contract or results | `docs/CONFORMANCE.md` |
| Install / usage / requirements / debugging | `README.md` |
| How to build/test/work here | `CONTRIBUTING.md` |
| Cross-platform or sandbox design | `docs/design/` |

Rules for doc edits: state what changed and why, plainly; subtract stale lines
rather than piling on; don't duplicate the same fact across files (link instead).

**Ship the doc edit in the SAME patch as the change — always, no exceptions.**
Work here is delivered as `git format-patch` files, so "update the doc before the
work is done" means the doc edit is a hunk in that same patch, not a follow-up.
A patch that changes a CLI name, a flag, an env var, a requirement, install
steps, tool discovery, or any user-visible behavior is **incomplete** until
`README.md` (and any other row above) is updated in it. If you catch a doc that
already lags the code, fix it in the next patch you send rather than leaving it.
This is on you every time — there is no hook enforcing it.

## What this project is (the premise, don't violate it)

mruby-lsp is a **standalone** LSP server for mruby. The **live, compiled mruby
VM is the sole source of truth** — no RBS, no CRuby conventions, no static file
indexing. Each project compiles its own runtime; the built binary is the ground
truth about what APIs exist. If a method is in the build, it completes; if not,
it doesn't. It is *not* a ruby-lsp addon: ruby-lsp's CRuby-source-of-truth model
is incompatible with this premise.

## How to work here

- **Verify by running.** Unbuilt, undriven code does not count as done. Drive the
  server over real LSP stdio; don't rely on static inspection or C test drivers.
  If output wasn't shown, it didn't happen.
- **Whole-file delivery.** No patches unless verified `git apply`-clean.
- **Subtractions over additions.** Prefer deleting to adding; don't over-engineer.
- **No `mrb_load_string` / eval** anywhere in mruby contexts. Executing buffer
  code is the security line; reading the already-loaded image is fine.
- **No regex on nested/structured input** (Ruby, JSON, HTML/XML, compiler command
  lines, structured machine output). Use a real parser or the structured data in
  hand: Ruby → Prism; C locations → addr2line/nm tooling; reflection → consumed
  structurally. Regex matches regular languages only.
- **Keep regex out of hot paths** — backtracking engines go superlinear on
  adversarial input. Prefer `memchr`/`String#index`/a tight hand scanner.
- **C is a dumb bridge**: only what FFI supports; all logic in Ruby. The VM
  decides; C never dispatches.
- **Degrade, don't crash.** Optional subsystems (e.g. clangd for C) are BYO and
  may be absent or die mid-session; turn the feature off and keep the server
  alive. Users bring their own toolchain — never force-install one.

## Commits & patches (maintainer preference)

- **Never put a session URL in a commit message.** A `claude.ai/code/session_…`
  (or any session) link lands permanently in history, is world-readable, and
  hands an attacker a concrete endpoint to probe. Leave it out entirely.
- **Do NOT add a `Co-Authored-By:` trailer for the agent.** GitHub parses that
  trailer and renders the agent as a co-author with name + avatar in its UI —
  the maintainer does not want the agent listed among a commit's authors. A
  plain-text mention in the body (a line that is NOT a recognized trailer) is
  acceptable if attribution is wanted: it shows in `git log` but GitHub does not
  treat it as an author.
- **Author = the maintainer, not the agent.** Set the commit author to the repo
  owner's GitHub identity. Find it via the API instead of guessing:
  - Call the GitHub MCP tool `get_me` → it returns `login`, `id`, and
    `details.name` (here: `Asmod4n`, `791770`, `Hendrik`). For someone else, use
    `search_users`.
  - GitHub's privacy-preserving commit email is `<id>+<login>@users.noreply.
    github.com` → `791770+Asmod4n@users.noreply.github.com`. This is what GitHub
    attributes back to the account; do NOT invent a plain address.
  - Apply it: `git -c user.name=<name> -c user.email=<id>+<login>@users.
    noreply.github.com commit --amend --reset-author` (or set it before
    committing).
- **Delivery: a `git format-patch` file, not a branch/push** unless explicitly
  asked. `git am` replays the recorded author cleanly on the maintainer's side.
- **Generated/version-bumped files never block a merge.** `.gitattributes` marks
  the `rake`-regenerated files (`lib/mruby_lsp/version.rb`,
  `vendor/value_bridge/lib/value_bridge/version.rb`, `share/mtimes.json`,
  `editors/vscode/vendor/gems/manifest.json`, `editors/vscode/package.json`) as
  `merge=ours`, so a merge always keeps our side and they never conflict. The
  `ours` driver is registered per-clone by `rake` (gem:bump runs
  `git config merge.ours.driver true`); set it by hand in a clone that never runs
  rake. NOTE the package.json caveat in `.gitattributes`.

## Environment

Arch/CachyOS, Fish, VSCodium. Ruby 3.4 (host), mruby 4.0.0, GCC 13, Node 22.
Prism for Ruby parsing; addr2line/llvm-symbolizer/atos + nm for C locations;
transport via the `language_server-protocol` gem.
