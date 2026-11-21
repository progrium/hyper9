// One machine per Worker (design/epoch-0/browser-host.md): runs h9 with the
// page's mounts and argv, and passes the console through messages. The
// page's side is createMachine in h9-web.js.
//
// Page to Worker: { type: 'start', argv, env, mounts, tty, gfx } once, then
// { type: 'input', data }, { type: 'interrupt' } and { type: 'hangup' },
// and { type: 'put', path, data, mode } at any time, which adds a file to
// the first archive's tree (before start, once it's loaded).
// Worker to page: { type: 'output', fd, data }, { type: 'raw', on } and
// { type: 'exit', code } or { type: 'error', message }.
//
// With start's `credentials` set, the page has a credentials callback
// (design/credential-helpers.md, "Browser host"): the Worker sends
// { type: 'cred', id, url, failed, helper } before each handshake h9
// makes, and the page answers { type: 'cred-reply', id, result } or
// { type: 'cred-reply', id, error }.
//
// With a canvas (design/epoch-0/browser-gfx.md), start's gfx is { canvas,
// width, height }, the OffscreenCanvas and the screen's size, and the page
// sends { type: 'gfx', ev }, { type: 'gfx-paste', text } and
// { type: 'gfx-size', width, height }; the Worker sends { type: 'cursor',
// data } and { type: 'snarf', text }.

import { run, Panic, GfxHost, canDrawInWorker, mountFlag } from './h9-web.js';
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

// The tree WASI serves, once loaded, and puts that came before it, which
// go under the first archive's directory, putAt.
let tree = null;
let putAt = '';
const puts = [];
const put = ({ path, data, mode }) => {
  try {
    putNode(tree, `${putAt}/${path.replace(/^\/+/, '')}`, mode, new Uint8Array(data));
  } catch (e) {
    console.error(`h9: put ${path}: ${e.message}`);
  }
};

// The page's answers to credentials requests, by id.
const credWaits = new Map();
let credNext = 1;
const askPage = (url, failed, helper) => new Promise((resolve, reject) => {
  const id = credNext++;
  credWaits.set(id, { resolve, reject });
  post({ type: 'cred', id, url, failed, helper });
});

async function start({ argv, env = {}, mounts = [], tty = false, gfx: canvas, credentials = false }) {
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
  // Each archive is unpacked into the tree WASI serves, under /.mnt/N, and
  // mounted from there as a --dir (design/mounts.md), so archives on one
  // destination stack as the CLI's do.
  const archives = mounts.map((m, i) => ({ m, at: `/.mnt/${i}` })).filter(({ m }) => m.kind === 'archive');
  const [h9, ...bytes] = await Promise.all([
    fetchBytes(new URL('h9.wasm', import.meta.url)),
    ...archives.map(({ m }) => fetchBytes(m.src)),
  ]);
  tree = parseRoot(new TextEncoder().encode('h9root1\n'));
  bytes.forEach((a, i) => parseRoot(a, tree, archives[i].at));
  putAt = archives.length ? archives[0].at : '';
  puts.splice(0).forEach(put);
  const flags = mounts.map((m, i) => mountFlag(m, m.kind === 'archive' ? `/.mnt/${i}` : m.src));
  return run({
    h9,
    wasi: (memory) => wasiImports({
      memory,
      root: tree,
      args: ['h9', ...flags, ...argv],
      env: { PWD: '/', ...env },
      write: (fd, data) => post({ type: 'output', fd, data }, [data.buffer]),
      tty,
    }),
    host,
    gfx,
    credentials: credentials ? askPage : undefined,
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
    case 'cred-reply': {
      const w = credWaits.get(m.id);
      credWaits.delete(m.id);
      if (m.error != null) w?.reject(new Error(m.error)); else w?.resolve(m.result);
      break;
    }
    case 'interrupt': raise(1); break;
    case 'hangup': raise(2); break;
    case 'gfx': gfx?.input(m.ev); break;
    case 'gfx-paste': gfx?.paste(m.text); break;
    case 'gfx-size': gfx?.resize(m.width, m.height); break;
  }
};
