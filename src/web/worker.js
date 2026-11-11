// One machine per Worker (design/0012-browser-host.md): runs h9 with the
// page's argv over the root archive or a ws:// root, and passes the console through
// messages. The page's side is createMachine in h9-web.js.
//
// Page to Worker: { type: 'start', argv, env, root, layers, tty, gfx } once, then
// { type: 'input', data }, { type: 'interrupt' } and { type: 'hangup' },
// and { type: 'put', path, data, mode } at any time, which adds a file to
// the root's tree (before start, once it's loaded).
// Worker to page: { type: 'output', fd, data }, { type: 'raw', on } and
// { type: 'exit', code } or { type: 'error', message }.
//
// With a canvas (design/0120-browser-gfx.md), start's gfx is { canvas,
// width, height }, the OffscreenCanvas and the screen's size, and the page
// sends { type: 'gfx', ev }, { type: 'gfx-paste', text } and
// { type: 'gfx-size', width, height }; the Worker sends { type: 'cursor',
// data } and { type: 'snarf', text }.

import { run, Panic, GfxHost, canDrawInWorker } from './h9-web.js';
import { parseRoot, putNode, wasiImports } from './wasi-mem.js';

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

let gfx = null;

// The root's tree, once loaded, and puts that came before it.
let tree = null;
const puts = [];
const put = ({ path, data, mode }) => {
  try {
    putNode(tree, path, mode, new Uint8Array(data));
  } catch (e) {
    console.error(`h9: put ${path}: ${e.message}`);
  }
};

async function start({ argv, env = {}, root, layers = [], tty = false, gfx: canvas }) {
  if (canvas) {
    if (!canDrawInWorker()) throw new Error("this browser can't draw from a Worker");
    gfx = new GfxHost({ ...canvas, post });
  }
  const fetchBytes = async (url) => {
    // Revalidated, not taken from the HTTP cache unchecked: GitHub Pages
    // lets browsers cache for 10 minutes, and a stale h9.wasm with a new
    // page or archive fails in confusing ways.
    const r = await fetch(url, { cache: 'no-cache' });
    if (!r.ok) throw new Error(`${url}: ${r.status} ${r.statusText}`);
    return new Uint8Array(await r.arrayBuffer());
  };
  // A ws:// or wss:// root is served over a WebSocket
  // (design/0021-websocket-9p.md), and WASI sees only the layers. An
  // archive root is the bottom layer, and root.h9a is the default when
  // there are no layers.
  const remote = typeof root === 'string' && /^wss?:/i.test(root);
  const base = remote ? [] : root ? [{ url: root }] : layers.length ? [] : [{ url: new URL('root.h9a', import.meta.url) }];
  const all = [...base, ...layers];
  const [h9, ...archives] = await Promise.all([
    fetchBytes(new URL('h9.wasm', import.meta.url)),
    ...all.map((l) => fetchBytes(l.url)),
  ]);
  // Each layer adds its files over the ones before it, under its `at`.
  tree = parseRoot(new TextEncoder().encode('h9root1\n'));
  archives.forEach((a, i) => parseRoot(a, tree, all[i].at ?? '/'));
  puts.splice(0).forEach(put);
  return run({
    h9,
    wasi: (memory) => wasiImports({
      memory,
      root: tree,
      // The layers are the whole tree WASI sees, so the root is /.
      args: ['h9', '--root', remote ? root : '/', ...argv],
      env: { PWD: '/', ...env },
      write: (fd, data) => post({ type: 'output', fd, data }, [data.buffer]),
      tty,
    }),
    host,
    gfx,
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
    case 'put': if (tree) put(m); else puts.push(m); break;
    case 'interrupt': raise(1); break;
    case 'hangup': raise(2); break;
    case 'gfx': gfx?.input(m.ev); break;
    case 'gfx-paste': gfx?.paste(m.text); break;
    case 'gfx-size': gfx?.resize(m.width, m.height); break;
  }
};
