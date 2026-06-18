'use strict';
// Drives MrdbDebugSession via the DAP entry point (handleMessage) with a FAKE
// driver, asserting the responses + events the official DebugSession emits. No
// vscode, no real mrdb — pure protocol logic. Run: node mrdbDebugSession.test.js

const assert = require('assert');
const { MrdbDebugSession } = require('./mrdbDebugSession');

let fails = 0;
function check(label, got, want) {
  let ok;
  try { assert.deepStrictEqual(got, want); ok = true; } catch (_) { ok = false; }
  if (!ok) fails++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok) console.log(`        got:  ${JSON.stringify(got)}\n        want: ${JSON.stringify(want)}`);
}

function makeSession() {
  const d = { cmds: [], opts: null, bp: 0, locals: [], values: {}, entry: null };
  const api = {
    async start() { d.cmds.push('start'); this.entry = d.entry; },
    async run() { d.cmds.push('run'); },
    async setLineBreakpoint(line) { d.cmds.push('break:' + line); return ++d.bp; },
    async deleteBreakpoint(n) { d.cmds.push('delete:' + n); },
    async continue() { d.cmds.push('continue'); },
    async next() { d.cmds.push('next'); },
    async step() { d.cmds.push('step'); },
    async localNames() { return d.locals; },
    async evaluate(expr) { return d.values[expr] || { value: '' }; },
    quit() { d.cmds.push('quit'); },
    dispose() { d.cmds.push('dispose'); },
  };
  const session = new MrdbDebugSession((_p, _prog, opts) => { d.opts = opts; return api; });
  const out = [];
  session.onDidSendMessage((m) => out.push(m));
  return { session, out, d };
}

let seq = 0;
// Send a DAP request and RESOLVE once the matching response is emitted. The
// official DebugSession runs request handlers asynchronously and tags each
// response with request_seq, so we wait for that rather than the void return of
// handleMessage (which is fire-and-forget).
function req(session, out, command, args) {
  const s = ++seq;
  return new Promise((resolve) => {
    const poll = () => {
      const r = out.find((m) => m.type === 'response' && m.request_seq === s);
      if (r) return resolve(r);
      setImmediate(poll);
    };
    session.handleMessage({ seq: s, type: 'request', command, arguments: args || {} });
    setImmediate(poll);
  });
}
const responsesOf = (out, command) => out.filter((m) => m.type === 'response' && m.command === command);
const eventsOf = (out, event) => out.filter((m) => m.type === 'event' && m.event === event);

(async () => {
  const { session, out, d } = makeSession();

  // initialize: capabilities, NO initialized event yet (VS Code always sends
  // pathFormat:'path'; the official base class requires it).
  await req(session, out, 'initialize', { adapterID: 'mruby', pathFormat: 'path', linesStartAt1: true, columnsStartAt1: true });
  const init = responsesOf(out, 'initialize')[0];
  check('initialize advertises configurationDone', init.body.supportsConfigurationDoneRequest, true);
  check('initialize advertises eval-for-hovers', init.body.supportsEvaluateForHovers, true);
  check('no InitializedEvent before launch', eventsOf(out, 'initialized').length, 0);

  // launch: starts the driver, THEN emits initialized
  await req(session, out, 'launch', { program: '/tmp/work/test.rb' });
  check('driver started on launch', d.cmds.includes('start'), true);
  check('InitializedEvent after mrdb up', eventsOf(out, 'initialized').length, 1);
  check('launch responded', responsesOf(out, 'launch').length, 1);

  // setBreakpoints: clears nothing first time, binds each line, reports verified
  await req(session, out, 'setBreakpoints', { source: { path: '/tmp/work/test.rb' }, breakpoints: [{ line: 8 }, { line: 12 }] });
  const sbp = responsesOf(out, 'setBreakpoints')[0];
  check('two breakpoints verified', sbp.body.breakpoints.map((b) => b.verified), [true, true]);
  check('break commands sent', d.cmds.filter((c) => c.startsWith('break:')), ['break:8', 'break:12']);

  // re-setting clears the previously created mrdb breakpoints first
  await req(session, out, 'setBreakpoints', { source: { path: '/tmp/work/test.rb' }, breakpoints: [{ line: 8 }] });
  check('re-set deletes prior bps', d.cmds.filter((c) => c.startsWith('delete:')).sort(), ['delete:1', 'delete:2']);

  // configurationDone -> run
 await req(session, out, 'configurationDone', {});
  check('run started after configurationDone', d.cmds.includes('run'), true);

  // simulate mrdb stopping at a breakpoint
  d.opts.onStopped({ file: '/tmp/work/test.rb', line: 8 });
  const stopped = eventsOf(out, 'stopped')[0];
  check('stopped event reason', stopped.body.reason, 'breakpoint');
  check('stopped threadId', stopped.body.threadId, 1);

  // threads / stackTrace / scopes
 await req(session, out, 'threads', {});
  check('one thread', responsesOf(out, 'threads')[0].body.threads.map((t) => t.name), ['main']);
 await req(session, out, 'stackTrace', { threadId: 1 });
  const st = responsesOf(out, 'stackTrace')[0].body;
  check('single frame at stop line', [st.totalFrames, st.stackFrames[0].line], [1, 8]);
 await req(session, out, 'scopes', { frameId: 1 });
  check('locals scope', responsesOf(out, 'scopes')[0].body.scopes[0].name, 'Locals');

  // variables: names from localNames, values from evaluate
  d.locals = ['x', 'payload'];
  d.values = { x: { value: '42' }, payload: { value: '{"a"=>1}' } };
  await req(session, out, 'variables', { variablesReference: 1 });
  const vars = responsesOf(out, 'variables')[0].body.variables;
  check('variable names', vars.map((v) => v.name), ['x', 'payload']);
  check('variable values', vars.map((v) => v.value), ['42', '{"a"=>1}']);

  // stepping maps to the right mrdb verbs
  await req(session, out, 'continue', { threadId: 1 });
  await req(session, out, 'next', { threadId: 1 });
  await req(session, out, 'stepIn', { threadId: 1 });
  await req(session, out, 'stepOut', { threadId: 1 });
  check('continue/next/stepIn/stepOut verbs',
    d.cmds.filter((c) => ['continue', 'next', 'step'].includes(c)),
    ['continue', 'next', 'step', 'next']); // stepOut -> next

  // evaluate (watch/hover/repl)
  d.values['1 + 1'] = { value: '2' };
  await req(session, out, 'evaluate', { expression: '1 + 1', context: 'watch' });
  check('evaluate result', responsesOf(out, 'evaluate')[0].body.result, '2');
  d.values['boom'] = { error: 'undefined (NameError)' };
  await req(session, out, 'evaluate', { expression: 'boom', context: 'repl' });
  check('evaluate error surfaced', responsesOf(out, 'evaluate').slice(-1)[0].body.result, '<error: undefined (NameError)>');

  // .rb program -> source mode (no -b) on the driver opts
  check('rb launch is source mode', !d.opts.mrbfile, true);

  // program exit -> TerminatedEvent
  d.opts.onExited();
  check('terminated on exit', eventsOf(out, 'terminated').length, 1);

  // disconnect cleans up
  await req(session, out, 'disconnect', {});
  check('disconnect quits + disposes', d.cmds.includes('quit') && d.cmds.includes('dispose'), true);

  // .mrb program -> bytecode mode flows through to the driver opts
  {
    const s2 = makeSession();
    await req(s2.session, s2.out, 'initialize', { adapterID: 'mruby', pathFormat: 'path' });
    await req(s2.session, s2.out, 'launch', { program: '/tmp/work/app.mrb' });
    check('.mrb launch sets bytecode mode', s2.d.opts.mrbfile, true);
  }

  // stop-on-entry (default): mrdb launches paused on the first line; the adapter
  // reports THAT stop (no run yet), and the first resume is `run`.
  {
    const s = makeSession();
    s.d.entry = { file: 'app.rb', line: 1 };
    await req(s.session, s.out, 'initialize', { adapterID: 'mruby', pathFormat: 'path' });
    await req(s.session, s.out, 'launch', { program: '/tmp/work/app.rb' }); // no stopOnEntry -> default on
    await req(s.session, s.out, 'configurationDone', {});
    const st = s.out.filter((m) => m.type === 'event' && m.event === 'stopped');
    check('stop-on-entry reports a stop', st.length, 1);
    check('stop-on-entry reason', st[0].body.reason, 'entry');
    check('stop-on-entry did NOT run yet', s.d.cmds.includes('run'), false);
    // first resume is run (honors later breakpoints)
    await req(s.session, s.out, 'continue', { threadId: 1 });
    check('first resume from entry uses run', s.d.cmds.includes('run'), true);
  }

  // breakpoint ON the entry line: even with stopOnEntry off, report the stop
  // (mrdb skips the first fetch, so `run` would walk past it).
  {
    const s = makeSession();
    s.d.entry = { file: 'one.rb', line: 2 };
    await req(s.session, s.out, 'initialize', { adapterID: 'mruby', pathFormat: 'path' });
    await req(s.session, s.out, 'launch', { program: '/tmp/work/one.rb', stopOnEntry: false });
    await req(s.session, s.out, 'setBreakpoints', { source: { path: '/tmp/work/one.rb' }, breakpoints: [{ line: 2 }] });
    await req(s.session, s.out, 'configurationDone', {});
    const st = s.out.filter((m) => m.type === 'event' && m.event === 'stopped');
    check('breakpoint-on-entry reports a stop', st.length, 1);
    check('breakpoint-on-entry reason', st[0].body.reason, 'breakpoint');
    check('breakpoint-on-entry did NOT run', s.d.cmds.includes('run'), false);
  }

  // driver builds the right mrdb argv for each mode (no program args to mrdb)
  const { MrdbDriver } = require('./mrdbDriver');
  const rb = new MrdbDriver('mrdb', '/p/test.rb', {});
  check('source argv = [file]', rb._argv(), ['test.rb']);
  const mrb = new MrdbDriver('mrdb', '/p/app.mrb', {});
  check('bytecode argv = [-b, -d dir, file]', mrb._argv(), ['-b', '-d', '/p', 'app.mrb']);

  // program output = block minus the trailing mrdb prompt (so puts / exception
  // text reaches the Debug Console; query responses are NOT forwarded).
  check('programOutput strips trailing prompt (keeps program newlines)',
    rb._programOutput('hi from puts\nNoMethodError raised\n(test.rb:3) '),
    'hi from puts\nNoMethodError raised\n');
  check('programOutput with no prompt kept verbatim', rb._programOutput('plain output\n'), 'plain output\n');

  // setLineBreakpoint binds via `break` and returns the bp number (mrdb creates
  // breakpoints already enabled; no `enable` needed). Unbound source -> null.
  {
    const d3 = new MrdbDriver('mrdb', '/p/foo.rb', {});
    const sent = [];
    d3.send = async (cmd) => {
      sent.push(cmd);
      return cmd.startsWith('break') ? 'Breakpoint 1: file foo.rb, line 2.\n(foo.rb:2) ' : '(foo.rb:2) ';
    };
    check('setLineBreakpoint returns bpno', await d3.setLineBreakpoint(2), 1);
    check('only break sent (no enable)', sent, ['break foo.rb:2']);

    const d4 = new MrdbDriver('mrdb', '/p/foo.rb', {});
    d4.send = async () => 'Line 9 in file "foo.rb" is unavailable.\n(foo.rb:2) ';
    check('unavailable line -> null', await d4.setLineBreakpoint(9), null);
  }

  // spawn of a missing mrdb -> start() REJECTS (no silent hang) + error surfaced
  // + exit fired, so launchRequest can report a real failure.
  let outSeen = '', exited = false, rejected = false;
  const bad = new MrdbDriver('/no/such/mrdb-xyzzy', '/tmp/x.rb', {
    onOutput: (t) => { outSeen += t; },
    onExited: () => { exited = true; },
  });
  try { await bad.start(); } catch (_) { rejected = true; }
  check('missing mrdb -> start() rejects', rejected, true);
  check('missing mrdb -> error surfaced to output', outSeen.includes('could not be started'), true);
  check('missing mrdb -> exited fired', exited, true);

  console.log('');
  console.log(fails === 0 ? 'ALL PASS' : `${fails} FAILED`);
  process.exit(fails === 0 ? 0 : 1);
})();
