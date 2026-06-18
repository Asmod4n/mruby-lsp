'use strict';
// mrdbDebugSession — a Debug Adapter Protocol server for mruby, built on the
// OFFICIAL @vscode/debugadapter library (DebugSession base class handles seq,
// framing and request/response correlation). It translates DAP requests into
// mrdb commands via MrdbDriver, and mrdb's stop/exit/output callbacks into DAP
// events. No DAP wire code is hand-rolled here; only the mrdb dialect is (in
// mrdbDriver).
//
// Scope (mrdb's own limits, see mrdbDriver header):
//   - LAUNCH only (no attach); one program, one thread.
//   - Breakpoints bind only in the launched program file (mrdb matches the path
//     it was started with); breakpoints in other files won't verify.
//   - The stack is a SINGLE frame (mrdb has no backtrace) taken from the stop.
//   - step over = mrdb `next`, step in = `step`; mrdb has NO step-out, so it is
//     approximated with `next` (documented; the button still works sensibly).
//   - Locals come from `info locals` (names) + `print <name>` (values).
//
// The InitializedEvent is emitted only AFTER mrdb has started, so the
// breakpoints VS Code sends in response to it bind against a running mrdb.

const path = require('path');
const {
  DebugSession, InitializedEvent, TerminatedEvent, StoppedEvent, OutputEvent,
  Thread, StackFrame, Scope, Variable, Source, Handles,
} = require('@vscode/debugadapter');
const { MrdbDriver } = require('./mrdbDriver');

const THREAD_ID = 1;
const LOCALS_REF = 1; // single, fixed scope reference (one frame, one scope)

class MrdbDebugSession extends DebugSession {
  // driverFactory: (mrdbPath, program, opts) -> driver. Injectable for tests;
  // defaults to the real MrdbDriver.
  constructor(driverFactory) {
    super();
    this.setDebuggerLinesStartAt1(true);
    this.setDebuggerColumnsStartAt1(true);
    this._driverFactory = driverFactory || ((mrdbPath, program, opts) => new MrdbDriver(mrdbPath, program, opts));
    this.driver = null;
    this.program = null;
    this.lastStop = null;     // { file, line }
    this.bpNums = [];         // mrdb breakpoint numbers we created (for clearing)
    this.bpLines = [];        // breakpoint LINES requested for the program
    this.entry = null;        // { file, line } where mrdb paused on launch
    this.stopOnEntry = false; // pause on the first line at launch
    this.started = false;     // has the program begun executing? (first go = run)
    this.handles = new Handles();
  }

  initializeRequest(response, _args) {
    response.body = response.body || {};
    response.body.supportsConfigurationDoneRequest = true;
    response.body.supportsEvaluateForHovers = true;
    response.body.supportsTerminateRequest = true;
    response.body.supportsStepInTargetsRequest = false;
    // NOTE: InitializedEvent is sent from launchRequest, after mrdb is up.
    this.sendResponse(response);
  }

  async launchRequest(response, args) {
    this.program = args.program;
    if (!this.program) {
      this.sendErrorResponse(response, 3000, 'launch: no "program" given');
      return;
    }
    // Default ON: mrdb launches already paused at the first line (its prompt is
    // a real, inspectable stop — info locals / list / eval all work there), so
    // we surface that as the initial DAP stop. The user lands paused on line 1
    // and drives from there. Opt out with "stopOnEntry": false.
    this.stopOnEntry = args.stopOnEntry !== false;
    const mrdbPath = args.mrdb || 'mrdb';
    const knownCat = (c) => (c === 'stderr' || c === 'console' ? c : 'stdout');
    this.driver = this._driverFactory(mrdbPath, this.program, {
      cwd: args.cwd,
      // .rb runs as source; .mrb runs as bytecode (-b). `sourceDir` (-d) lets
      // mrdb find the .rb sources a .mrb references; the driver defaults it to
      // the program's directory. The program file is the entry; no args go to
      // mrdb — whatever starts the program lives inside that file.
      mrbfile: String(this.program).toLowerCase().endsWith('.mrb'),
      srcpath: args.sourceDir,
      trace: args.trace === true,
      onStopped: (loc) => {
        this.lastStop = loc;
        this.sendEvent(new StoppedEvent('breakpoint', THREAD_ID));
      },
      onExited: () => this.sendEvent(new TerminatedEvent()),
      onOutput: (text, channel) => this.sendEvent(new OutputEvent(text, knownCat(channel))),
    });
    try {
      await this.driver.start();
    } catch (e) {
      this.sendErrorResponse(response, 3001, `failed to start mrdb (${mrdbPath}): ${e && e.message}`);
      this.driver = null;
      return;
    }
    this.entry = this.driver.entry || null; // line mrdb is positioned at on launch
    this.sendResponse(response);
    // mrdb is up: now invite breakpoints, which bind against the running session.
    this.sendEvent(new InitializedEvent());
  }

  async setBreakPointsRequest(response, args) {
    const requested = (args.breakpoints || []).map((b) => b.line);
    this.bpLines = requested; // for the entry-line check at configurationDone
    const verified = [];
    if (this.driver) {
      // mrdb accumulates breakpoints with no "set" semantics, so clear the ones
      // we made before re-applying the editor's current set (idempotent re-sync).
      for (const n of this.bpNums) await this.driver.deleteBreakpoint(n);
      this.bpNums = [];
      const file = (args.source && (args.source.name || args.source.path)) || this.program;
      for (const line of requested) {
        const num = await this.driver.setLineBreakpoint(line);
        if (num != null) this.bpNums.push(num);
        verified.push({ verified: num != null, line });
        // Surface binding outcome so an ignored breakpoint is explainable (mrdb
        // binds by the launched file's path; a mismatch leaves it unbound).
        this.sendEvent(new OutputEvent(
          `breakpoint ${file}:${line} ${num != null ? `bound (#${num})` : 'NOT bound by mrdb'}\n`,
          'console',
        ));
      }
    } else {
      for (const line of requested) verified.push({ verified: false, line });
    }
    response.body = { breakpoints: verified };
    this.sendResponse(response);
  }

  configurationDoneRequest(response, _args) {
    this.sendResponse(response);
    if (!this.driver) return;
    // mrdb launches positioned ON the first executable line and never
    // breakpoint-checks that first fetch, so `run` walks past a breakpoint there
    // AND past the very start of a one-line "runner" script. To make both work,
    // PAUSE at launch when stopOnEntry is set or a breakpoint is on the entry
    // line: report the stop we're already at, and let the user step into / run
    // on. The first resume is `run` (which honors later breakpoints); see
    // continueRequest. Otherwise just `run`.
    const entryLine = this.entry && this.entry.line;
    const breakAtEntry = entryLine != null && this.bpLines.includes(entryLine);
    if (this.entry && (this.stopOnEntry || breakAtEntry)) {
      this.lastStop = this.entry;
      this.sendEvent(new StoppedEvent(breakAtEntry ? 'breakpoint' : 'entry', THREAD_ID));
    } else {
      this.started = true;
      this.driver.run();
    }
  }

  threadsRequest(response) {
    response.body = { threads: [new Thread(THREAD_ID, 'main')] };
    this.sendResponse(response);
  }

  stackTraceRequest(response, _args) {
    const frames = [];
    if (this.lastStop) {
      // mrdb reports the file by the basename it was launched with (relative);
      // the editor needs an ABSOLUTE path to open it. mrdb debugs the one
      // launched program, so the stop is always in `this.program`.
      const abs = this.program || this.lastStop.file;
      const src = new Source(path.basename(abs), abs);
      frames.push(new StackFrame(1, path.basename(abs), src, this.lastStop.line, 1));
    }
    response.body = { stackFrames: frames, totalFrames: frames.length };
    this.sendResponse(response);
  }

  scopesRequest(response, _args) {
    response.body = { scopes: [new Scope('Locals', LOCALS_REF, false)] };
    this.sendResponse(response);
  }

  async variablesRequest(response, _args) {
    const variables = [];
    if (this.driver) {
      const names = await this.driver.localNames();
      for (const name of names) {
        const r = await this.driver.evaluate(name);
        variables.push(new Variable(name, r && r.error ? `<error: ${r.error}>` : String((r && r.value) || ''), 0));
      }
    }
    response.body = { variables };
    this.sendResponse(response);
  }

  async continueRequest(response, _args) {
    this.sendResponse(response);
    if (!this.driver) return;
    // The FIRST go must be `run` (from DBG_INIT): it's what honors breakpoints on
    // later lines. After a real stop, `continue` resumes.
    if (this.started) await this.driver.continue();
    else { this.started = true; await this.driver.run(); }
  }

  async nextRequest(response, _args) {
    this.sendResponse(response);
    if (this.driver) { this.started = true; await this.driver.next(); }
  }

  async stepInRequest(response, _args) {
    this.sendResponse(response);
    if (this.driver) { this.started = true; await this.driver.step(); }
  }

  async stepOutRequest(response, _args) {
    // mrdb has no step-out; `next` is the closest sensible behavior.
    this.sendResponse(response);
    if (this.driver) { this.started = true; await this.driver.next(); }
  }

  async evaluateRequest(response, args) {
    let result = '';
    if (this.driver && args && args.expression) {
      const r = await this.driver.evaluate(args.expression);
      result = r && r.error ? `<error: ${r.error}>` : String((r && r.value) || '');
    }
    response.body = { result, variablesReference: 0 };
    this.sendResponse(response);
  }

  terminateRequest(response, _args) {
    if (this.driver) this.driver.quit();
    this.sendResponse(response);
  }

  disconnectRequest(response, _args) {
    if (this.driver) {
      this.driver.quit();
      this.driver.dispose();
      this.driver = null;
    }
    this.sendResponse(response);
  }
}

module.exports = { MrdbDebugSession };
