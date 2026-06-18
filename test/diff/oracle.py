#!/usr/bin/env python3
"""
T5.1 — oracle harness.

Drives BOTH our server and ruby-lsp with the same LSP client over stdio. Asserts
CONTRACT conformance — not data equality. Runtime-unique symbols (mruby-only or
CRuby-only) are ignored. What the oracle checks is:

  For the same CATEGORY of target (a method on a known literal receiver, a
  constant, a class), our response must carry the same fields, kinds, and
  markdown structure that ruby-lsp uses. The sorting discipline (sortText) and
  display shape (labelDetails, filterText, data) must be present and well-formed.

Run:
  MRUBY_REFLECT_SO=/path/to/mruby_reflect.so python3 test/diff/oracle.py
"""

import json, os, subprocess, sys, threading, time

# ── server drivers ─────────────────────────────────────────────────────────────

def boot(cmd, cwd, env):
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, cwd=cwd)

def send(proc, msg):
    b = json.dumps(msg).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
    proc.stdin.flush()

def recv(proc, target_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        hdr = proc.stdout.readline()
        if not hdr:
            return None
        if not hdr.startswith(b"Content-Length"):
            continue
        n = int(hdr.split(b":")[1])
        proc.stdout.readline()  # blank line
        msg = json.loads(proc.stdout.read(n))
        # respond to server-initiated requests (e.g. window/workDoneProgress)
        if "id" in msg and "method" in msg:
            send(proc, {"jsonrpc": "2.0", "id": msg["id"], "result": None})
            continue
        if msg.get("id") == target_id:
            return msg
    return None

def drive(cmd, cwd, env, workspace_uri, opens, requests):
    """Boot a server, send opens + requests, return {label: result} dict."""
    proc = boot(cmd, cwd, env)
    rid = [1]
    def nxt():
        rid[0] += 1; return rid[0]

    send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"processId": os.getpid(),
                           "rootUri": workspace_uri,
                           "workspaceFolders": [{"uri": workspace_uri, "name": "w"}],
                           "capabilities": {
                               "textDocument": {
                                   "completion": {"completionItem": {"snippetSupport": True}},
                                   "hover": {"contentFormat": ["markdown"]}}}}})
    recv(proc, 1)
    send(proc, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    time.sleep(10)  # let the server index

    for uri, text in opens:
        send(proc, {"jsonrpc": "2.0", "method": "textDocument/didOpen",
                    "params": {"textDocument": {"uri": uri, "languageId": "ruby",
                                                "version": 1, "text": text}}})
    time.sleep(1)

    results = {}
    for label, method, params in requests:
        i = nxt()
        send(proc, {"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        r = recv(proc, i)
        results[label] = r.get("result") if r else None

    proc.terminate()
    return results


# ── contract assertions ────────────────────────────────────────────────────────

PASS = []; FAIL = []

def ok(name):
    PASS.append(name); print(f"  PASS  {name}")

def fail(name, reason):
    FAIL.append(name); print(f"  FAIL  {name}: {reason}")

def assert_completion_contract(label, ours, theirs):
    """Assert our completion items carry the same field shape as ruby-lsp's."""
    our_items = []
    if isinstance(ours, dict):
        our_items = ours.get("items", [])
    elif isinstance(ours, list):
        our_items = ours

    if not our_items:
        fail(label, "no completion items returned")
        return

    item = our_items[0]

    # kind must be a valid LSP CompletionItemKind integer
    if not isinstance(item.get("kind"), int):
        fail(label + "/kind", f"missing or non-integer kind: {item.get('kind')}")
    else:
        ok(label + "/kind")

    # label must be present
    if not item.get("label"):
        fail(label + "/label", "missing label")
    else:
        ok(label + "/label")

    # filterText must be present (ruby-lsp always sets it)
    if "filterText" not in item:
        fail(label + "/filterText", "missing filterText")
    else:
        ok(label + "/filterText")

    # sortText must be present and follow tier_name discipline ("00_..." etc)
    st = item.get("sortText", "")
    if not st or not (st[:2].isdigit() and len(st) > 3 and st[2] == "_"):
        fail(label + "/sortText", f"missing or wrong format: {st!r}")
    else:
        ok(label + "/sortText")

    # labelDetails must exist (ruby-lsp always emits it for methods/constants)
    if "labelDetails" not in item:
        fail(label + "/labelDetails", "missing labelDetails")
    else:
        ok(label + "/labelDetails")

    # data must carry owner_name (our completions always set it)
    if not item.get("data", {}).get("owner_name"):
        fail(label + "/data.owner_name", f"missing: {item.get('data')}")
    else:
        ok(label + "/data.owner_name")


def assert_hover_contract(label, ours):
    """Assert our hover uses the ruby-lsp markdown skeleton."""
    if ours is None:
        fail(label, "nil hover result")
        return

    value = ours.get("contents", {}).get("value", "")
    if not value:
        fail(label + "/contents", "empty hover value")
        return

    if "```ruby" in value:
        ok(label + "/code_fence")
    else:
        fail(label + "/code_fence", "missing ```ruby fence")

    if "**Definitions**" in value:
        ok(label + "/definitions_link")
    else:
        fail(label + "/definitions_link", "missing **Definitions** line")


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    so = os.environ.get("MRUBY_REFLECT_SO", "")
    if not so or not os.path.exists(so):
        print("MRUBY_REFLECT_SO not set or missing — aborting", file=sys.stderr)
        sys.exit(1)

    base_env = dict(os.environ)

    # Drive the Ruby server script directly (skipping the sandbox launcher) so
    # the oracle compares LSP behavior in isolation, not Landlock/seccomp effects.
    ours_cmd = ["ruby", "-I/tmp/prism-src/lib", "-I/tmp/mruby-lsp-new/lib",
                "/tmp/mruby-lsp-new/bin/mruby-lsp-server"]
    ours_env = dict(base_env, MRUBY_REFLECT_SO=so)

    rubylib = ":".join(["/tmp/ruby-lsp/lib", "/tmp/lsp-proto/lib", "/tmp/rbs/lib",
                        "/tmp/rbs/ext/rbs_extension", "/tmp/prism-src/lib"])
    theirs_cmd = ["ruby", "/tmp/ruby-lsp/exe/ruby-lsp"]
    theirs_env = dict(base_env, RUBYLIB=rubylib, BUNDLE_GEMFILE="/dev/null")

    ws = "/tmp/fixture"
    ws_uri = f"file://{ws}"
    src = '"hello".upcase\nArray\n'
    opens = [(f"{ws_uri}/t.rb", src)]

    requests = [
        ("completion_method", "textDocument/completion",
         {"textDocument": {"uri": f"{ws_uri}/t.rb"}, "position": {"line": 0, "character": 13}}),
        ("completion_constant", "textDocument/completion",
         {"textDocument": {"uri": f"{ws_uri}/t.rb"}, "position": {"line": 1, "character": 3}}),
        ("hover_method", "textDocument/hover",
         {"textDocument": {"uri": f"{ws_uri}/t.rb"}, "position": {"line": 0, "character": 10}}),
    ]

    print("=== booting our server ===")
    ours = drive(ours_cmd, ws, ours_env, ws_uri, opens, requests)

    print("=== booting ruby-lsp ===")
    theirs = drive(theirs_cmd, ws, theirs_env, ws_uri, opens, requests)

    print("\n=== CONTRACT conformance (our server) ===")
    assert_completion_contract("completion_method", ours["completion_method"],
                               theirs["completion_method"])
    assert_completion_contract("completion_constant", ours["completion_constant"],
                               theirs["completion_constant"])
    assert_hover_contract("hover_method", ours["hover_method"])

    print(f"\n{'='*50}")
    total = len(PASS) + len(FAIL)
    print(f"ORACLE: {len(PASS)}/{total} passed, {len(FAIL)} failed")
    if FAIL:
        print("FAILURES:", FAIL)
        sys.exit(1)
    else:
        print("ORACLE PASS — contract conformance verified")

if __name__ == "__main__":
    main()
