'use strict';
// mrdbDriver — drives mruby's `mrdb` REPL over stdin/stdout and exposes a small
// promise API. mrdb is the debugger; this is only the bridge.
//
// Parsing rule: mrdb's output is a (small, regular) LANGUAGE, so we parse it
// STRUCTURALLY — split/partition/startsWith on literal separators, fields read
// by known position, dispatched by the command we just sent. No regular
// expressions. No C (pure Node-over-pipe).
//
// Empirically verified against mruby 4.0.0 (2026-04-20). Key facts the parser
// depends on:
//   - Prompt is `(<path>:<line>) ` with NO trailing newline; `(-:0) ` when the
//     program is not running. Paths contain `/` (and possibly `:`), so the
//     path/line split is taken from the RIGHT (rpartition on the last `:`).
//   - Breakpoints only bind when the breakpoint path matches the path mrdb was
//     launched with. Launch cwd = the file's directory and use that same path.
//   - There is NO backtrace command (`backtrace` -> "invalid command"): the
//     stack is a single frame taken from the stop location.
//   - A stop is announced by an event line `Breakpoint N, at <path>:<line>`;
//     when source is available the following prompt also carries the position.
//     The event line is the authority; the prompt is the fallback.
//   - mrdb may emit interactive confirmations ending in `(y or n) ` (e.g. on
//     quit while running) — these must be answered or the driver hangs.
//   - Prompts can stack in the buffer (`(-:0) (-:0) `); frame to the LAST one.

const { spawn } = require('child_process');
const path = require('path');

const PROMPT_TAIL = ') ';          // every prompt ends with this, no newline
const RUNNING_PROMPT_OPEN = '(';   // prompts start with '('
const CONFIRM_TAIL = '(y or n) ';  // interactive yes/no confirmation

class MrdbDriver {
  constructor(mrdbPath, program, opts = {}) {
    this.mrdbPath = mrdbPath;
    this.program = program;
    // mrdb resolves source relative to cwd and binds breakpoints by the launch
    // path; run from the program's directory and refer to it by basename.
    this.cwd = opts.cwd || path.dirname(program);
    this.launchName = opts.launchName || path.basename(program);
    // .mrb bytecode is run with `-b`; mrdb then needs `-d <dir>` to find the .rb
    // sources its debug_info references (for listing + breakpoints). Default the
    // source dir to the program's own directory unless the caller overrides.
    this.mrbfile = opts.mrbfile != null ? opts.mrbfile : String(program).toLowerCase().endsWith('.mrb');
    this.srcpath = opts.srcpath || (this.mrbfile ? this.cwd : null);
    this.proc = null;
    this.buf = '';
    this.pending = null;     // { resolve } awaiting the next framed block
    this.onStopped = opts.onStopped || (() => {});
    this.onExited = opts.onExited || (() => {});
    this.onOutput = opts.onOutput || (() => {});
    // trace: echo every command sent to mrdb and every raw block received to the
    // Debug Console (category 'console'), so breakpoint-binding / prompt-parsing
    // issues are diagnosable from the user's side.
    this.trace = !!opts.trace;
    this.exitedEmitted = false;
  }

  // mrdb argv: source mode is just the file; bytecode mode is `-b [-d src] file`.
  // No program/CLI args are passed to mrdb — the program file IS the entry (it
  // does whatever starting the app needs: top-level code, a main/__main__ call,
  // or invoking a method defined in another gem).
  _argv() {
    const a = [];
    if (this.mrbfile) a.push('-b');
    if (this.srcpath) a.push('-d', this.srcpath);
    a.push(this.launchName);
    return a;
  }

  start() {
    this.proc = spawn(this.mrdbPath, this._argv(), { cwd: this.cwd });
    // spawn failure (e.g. mrdb not on PATH / wrong mrubyLsp.mrdbPath) arrives as
    // an 'error' event — without this the initial _awaitBlock would hang forever
    // and the session would look "started" but do nothing. Surface it and reject
    // the pending wait so launchRequest fails with a real message.
    this.proc.on('error', (err) => {
      this.onOutput(`mrdb could not be started (${this.mrdbPath}): ${err.message}\n`, 'stderr');
      if (this.pending) { const p = this.pending; this.pending = null; p.reject(err); }
      if (!this.exitedEmitted) { this.exitedEmitted = true; this.onExited(); }
    });
    this.proc.stdout.on('data', (d) => this._onData(d.toString('utf8')));
    this.proc.stderr.on('data', (d) => this.onOutput(d.toString('utf8'), 'stderr'));
    this.proc.on('exit', () => {
      if (!this.exitedEmitted) { this.exitedEmitted = true; this.onExited(); }
    });
    // The first thing mrdb prints is its initial prompt; wait for it. mrdb
    // launches positioned AT the first executable line (e.g. "(foo.rb:2)").
    // Capture that entry line: a breakpoint ON it is skipped by the first run
    // (you don't break at the line you're already sitting on), so the session
    // reports the entry stop instead of running past it.
    if (this.trace) this.onOutput('» (start) ' + this.mrdbPath + ' ' + this._argv().join(' ') + '\n', 'console');
    const wait = this._awaitBlock();
    return wait.then((block) => {
      if (this.trace) this.onOutput('« ' + block + '\n', 'console');
      this.entry = this._promptLocation(block);
      return block;
    });
  }

  // ---- framing -------------------------------------------------------------

  _onData(chunk) {
    this.buf += chunk;
    // Auto-answer interactive confirmations so we never hang waiting on input.
    if (this._endsWithToken(this.buf, CONFIRM_TAIL)) {
      this.proc.stdin.write('y\n');
      this.buf = '';
      return;
    }
    if (this._endsWithPrompt(this.buf)) {
      const block = this.buf;
      this.buf = '';
      this._deliver(block);
    }
  }

  // True when the buffer currently ends at a prompt (= mrdb is awaiting input).
  // String-suffix test, not a pattern match: the buffer must end with `) ` and
  // the parenthesized tail after the last unmatched `(` must look like a
  // `<something>:<digits>` (or the literal `-:0`).
  _endsWithPrompt(s) {
    if (!s.endsWith(PROMPT_TAIL)) return false;
    const openIdx = s.lastIndexOf(RUNNING_PROMPT_OPEN);
    if (openIdx < 0) return false;
    const inside = s.slice(openIdx + 1, s.length - PROMPT_TAIL.length); // between ( and ")"
    // inside is "<path>:<line>" or "-:0". Take the last ':' as the separator.
    const sep = inside.lastIndexOf(':');
    if (sep < 0) return false;
    const lineStr = inside.slice(sep + 1);
    return lineStr.length > 0 && this._allDigits(lineStr);
  }

  _endsWithToken(s, tok) { return s.endsWith(tok); }

  _allDigits(s) {
    for (const ch of s) { if (ch < '0' || ch > '9') return false; }
    return s.length > 0;
  }

  _deliver(block) {
    // Surface program exit as an event regardless of the command.
    if (this._mentionsExit(block) && !this.exitedEmitted) {
      this.exitedEmitted = true;
      this.onExited();
    }
    // NOTE: we do NOT emit a stop here. A stop is only meaningful after a
    // run/continue/step (handled in those methods) — emitting from every framed
    // block would fire spurious stops on `print`, `break`, etc.
    if (this.pending) {
      const p = this.pending; this.pending = null; p.resolve(block);
    }
  }

  _awaitBlock() {
    return new Promise((resolve, reject) => { this.pending = { resolve, reject }; });
  }

  // The program's own output in a resume block: everything except the trailing
  // mrdb prompt. mrdb interleaves the debugged program's stdout with its prompts
  // on one stream, so we surface this to the Debug Console only for run/continue/
  // step (NOT for print/info/break queries, whose output is ours, not the
  // program's). Without this, puts and uncaught-exception text are invisible.
  _programOutput(block) {
    const i = block.lastIndexOf(RUNNING_PROMPT_OPEN);
    return i >= 0 ? block.slice(0, i) : block; // verbatim, minus the trailing prompt
  }

  // ---- command + structural readers ---------------------------------------

  // Send a command, await the framed response block (raw text).
  async send(cmd) {
    if (this.trace) this.onOutput('» ' + cmd + '\n', 'console');
    const wait = this._awaitBlock();
    this.proc.stdin.write(cmd + '\n');
    const block = await wait;
    if (this.trace) this.onOutput('« ' + block + '\n', 'console');
    return block;
  }

  // The current stop location from a block: prefer the event line
  // `Breakpoint N, at <path>:<line>`, else the trailing prompt position.
  _readStop(block) {
    for (const line of block.split('\n')) {
      const t = line.trim();
      if (t.startsWith('Breakpoint ') && t.includes(', at ')) {
        const afterAt = t.split(', at ')[1];          // "<path>:<line>"
        const loc = this._splitPathLine(afterAt);
        if (loc) return loc;
      }
    }
    return this._promptLocation(block);
  }

  // Position carried by the final prompt, when source is available.
  _promptLocation(block) {
    const openIdx = block.lastIndexOf(RUNNING_PROMPT_OPEN);
    if (openIdx < 0) return null;
    const close = block.indexOf(PROMPT_TAIL, openIdx);
    if (close < 0) return null;
    const inside = block.slice(openIdx + 1, close);   // "<path>:<line>" or "-:0"
    if (inside === '-:0') return null;                // not running
    return this._splitPathLine(inside);
  }

  // "<path>:<line>" -> { file, line }, split on the LAST colon (paths have /).
  _splitPathLine(s) {
    const sep = s.lastIndexOf(':');
    if (sep < 0) return null;
    const file = s.slice(0, sep);
    const lineStr = s.slice(sep + 1).trim();
    if (!this._allDigits(lineStr)) return null;
    return { file, line: parseInt(lineStr, 10) };
  }

  _mentionsExit(block) {
    for (const line of block.split('\n')) {
      if (line.trim() === 'mruby application exited.') return true;
    }
    return false;
  }

  // setBreakpoints: returns the mrdb breakpoint number for file:line, or null
  // if mrdb reported the source unavailable (breakpoint did not bind). mrdb
  // creates breakpoints already ENABLED (apibreak.c), so no `enable` is needed;
  // a breakpoint on a later line is honored by `run`. (A breakpoint on the entry
  // line is handled by the session reporting the launch stop — mrdb never
  // breakpoint-checks the first fetch.)
  async setLineBreakpoint(line) {
    const block = await this.send('break ' + this.launchName + ':' + line);
    for (const raw of block.split('\n')) {
      const t = raw.trim();
      if (t.startsWith('Breakpoint ') && t.includes(': file ')) {
        // "Breakpoint 1: file dbgwork.rb, line 8."
        return parseInt(t.slice('Breakpoint '.length).split(':')[0].trim(), 10);
      }
      if (t.startsWith('Source file named ') && t.endsWith('is unavailable.')) {
        return null; // did not bind — path mismatch or no source on disk
      }
    }
    return null;
  }

  // Remove a breakpoint by its mrdb number (mrdb `delete <n>`). Best-effort: the
  // response carries no reliable confirmation line, so we don't parse it.
  async deleteBreakpoint(num) { await this.send('delete ' + num); }

  async run() { return this._resume('run'); }
  async continue() { return this._resume('continue'); }
  async step() { return this._resume('step'); }     // step INTO (mrdb `step`)
  async next() { return this._resume('next'); }      // step OVER (mrdb `next`)

  // Local variable NAMES in the current frame, via `info locals` (mrdb evaluates
  // `local_variables` and prints `$N = [:a, :b, ...]`). Values are fetched
  // per-name with evaluate(). Returns [] when none / not running. mrdb has no
  // step-out; the session approximates it with `next`.
  async localNames() {
    const block = await this.send('info locals');
    for (const raw of block.split('\n')) {
      const t = raw.trim();
      if (t.startsWith('$') && t.includes(' = ')) {
        const rhs = t.split(' = ').slice(1).join(' = ').trim();   // "[:a, :b]" or "[]"
        if (!rhs.startsWith('[') || !rhs.endsWith(']')) return [];
        const inner = rhs.slice(1, -1).trim();
        if (inner === '') return [];
        return inner.split(',')
          .map((s) => { const n = s.trim(); return n.startsWith(':') ? n.slice(1) : n; })
          .filter((s) => s.length > 0);
      }
    }
    return [];
  }

  // A resume command (run/continue/step): send it, then report the resulting
  // stop (or exit) from THIS response only — not from arbitrary blocks.
  async _resume(cmd) {
    const block = await this.send(cmd);
    // Surface the program's own output (puts, uncaught-exception text, …) that
    // mrdb printed while running this step. Only here, not in query commands.
    const out = this._programOutput(block);
    if (out.trim()) this.onOutput(out, 'stdout'); // verbatim (already has newlines)
    if (this._mentionsExit(block)) {
      // exit already surfaced in _deliver; nothing to stop on.
      return block;
    }
    const stop = this._readStop(block);
    if (stop) this.onStopped(stop);
    return block;
  }

  // print <expr> -> value string, or { error } when mrdb returns an exception
  // (errors come back in the same "$N = ..." channel).
  async evaluate(expr) {
    const block = await this.send('print ' + expr);
    for (const raw of block.split('\n')) {
      const t = raw.trim();
      if (t.startsWith('$') && t.includes(' = ')) {
        const value = t.split(' = ').slice(1).join(' = ');
        // An exception value ends with "(SomeError)"; treat as eval error.
        if (value.endsWith('Error)') || value.includes('Error) for ')) {
          return { error: value };
        }
        return { value };
      }
    }
    return { value: '' };
  }

  async quit() {
    try { this.proc.stdin.write('quit\n'); } catch (_) {}
    // mrdb may ask "(y or n)" if still running; _onData answers it.
  }

  dispose() {
    try { this.proc && this.proc.kill(); } catch (_) {}
  }
}

module.exports = { MrdbDriver };
