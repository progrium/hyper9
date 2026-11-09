// One machine per Worker (design/0012-browser-host.md): runs h9 with the
// page's argv over the root archive or a ws:// root, and passes the console through
// messages. The page's side is createMachine in h9-web.js.
//
// Page to Worker: { type: 'start', argv, env, root, tty } once, then
// { type: 'input', data }, { type: 'interrupt' } and { type: 'hangup' }.
// Worker to page: { type: 'output', fd, data }, { type: 'raw', on } and
// { type: 'exit', code } or { type: 'error', message }.

import { run, Panic } from './h9-web.js';
import { parseRoot, wasiImports } from './wasi-mem.js';

const post = (m, t) => self.postMessage(m, t);

// Console input, one read per request; `cancelled` ends a read early.
let chunks = [];
let ended = false;
let waiting = null;
const deliver = () => {
  if (!waiting) return;
  const w = waiting;
  if (chunks.length) {
    let c = chunks.shift();
    if (c.length > w.n) { chunks.unshift(c.subarray(w.n)); c = c.subarray(0, w.n); }
    waiting = null;
    w.res(c);
  } else if (ended) {
    waiting = null;
    w.res(null);
  }
};

// Signals: 1 interrupt, 2 hangup, 0 to stop the watcher.
const sigq = [];
let sigwait = null;
const raise = (n) => { if (sigwait) { const r = sigwait; sigwait = null; r(n); } else sigq.push(n); };

const host = {
  readStdin: (n) => new Promise((res) => { waiting = { n, res }; deliver(); }),
  cancelStdin: () => { if (waiting) { const w = waiting; waiting = null; w.res('cancelled'); } },
  waitSignal: () => (sigq.length ? Promise.resolve(sigq.shift()) : new Promise((res) => { sigwait = res; })),
  stopSignals: () => raise(0),
  setRaw: (on) => post({ type: 'raw', on }),
};

async function start({ argv, env = {}, root, tty = false }) {
  const fetchBytes = async (url) => {
    // Revalidated, not taken from the HTTP cache unchecked: GitHub Pages
    // lets browsers cache for 10 minutes, and a stale h9.wasm with a new
    // page or archive fails in confusing ways.
    const r = await fetch(url, { cache: 'no-cache' });
    if (!r.ok) throw new Error(`${url}: ${r.status} ${r.statusText}`);
    return new Uint8Array(await r.arrayBuffer());
  };
  // A ws:// or wss:// root is served over a WebSocket
  // (design/0021-websocket-9p.md), and WASI sees an empty tree.
  const remote = typeof root === 'string' && /^wss?:/i.test(root);
  const [h9, v86, archive] = await Promise.all([
    fetchBytes(new URL('h9.wasm', import.meta.url)),
    fetchBytes(new URL('v86.wasm', import.meta.url)),
    remote ? new TextEncoder().encode('h9root1\n') : fetchBytes(root ?? new URL('root.h9a', import.meta.url)),
  ]);
  const tree = parseRoot(archive);
  return run({
    h9,
    v86,
    wasi: (memory) => wasiImports({
      memory,
      root: tree,
      // The archive is the whole tree WASI sees, so the root is /.
      args: ['h9', '--root', remote ? root : '/', ...argv],
      env: { PWD: '/', ...env },
      write: (fd, data) => post({ type: 'output', fd, data }, [data.buffer]),
      tty,
    }),
    host,
    log: (m) => console.log(m),
  });
}

self.onmessage = ({ data: m }) => {
  switch (m.type) {
    case 'start':
      start(m).then(
        (code) => post({ type: 'exit', code }),
        (e) => post({ type: 'error', message: e instanceof Panic ? `h9: panic: ${e.message}` : String(e?.stack ?? e) }),
      );
      break;
    case 'input':
      if (m.data === null) ended = true; else chunks.push(new Uint8Array(m.data));
      deliver();
      break;
    case 'interrupt': raise(1); break;
    case 'hangup': raise(2); break;
  }
};
