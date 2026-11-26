// The namespace kernel's Worker (design/namespace-kernel.md, The JS API):
// runs h9ns.wasm on the web host's coroutines, with an empty tree for
// WASI and no console. h9ns.js's createNamespaceKernel is the page's side.
// It runs as a browser Worker or a Node worker_threads Worker.
//
// Page to Worker: { type: 'start', wasm, maxMemory, ports } once, where
// wasm is h9ns.wasm's bytes, a WebAssembly.Module, or a URL, and ports an
// object from names to MessagePorts; then at any time
// { type: 'add-port', name, port }, { type: 'remove-port', name }, and
// { type: 'connect', port, aname }, which serves 9P2000 on port, attached
// to namespace aname (port-streams' port_accept, with port_aname).
// Worker to page: { type: 'started' } once h9ns.wasm is running, then
// { type: 'exit', code } or { type: 'error', message } if it ends.

import { run, Panic, Ports } from './h9-web.js';
import { parseRoot, wasiImports } from './wasi-mem.js';

let post, listen;
if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
  post = (m) => self.postMessage(m);
  listen = (f) => { self.onmessage = ({ data }) => f(data); };
} else {
  const { parentPort } = await import('node:worker_threads');
  post = (m) => parentPort.postMessage(m);
  listen = (f) => parentPort.on('message', f);
}

// The kernel's ports: the ones it mounts as port!NAME by name, and the
// ones it serves, with their attach names.
const ports = new Ports();
ports.serving = true;
const portOp = (f) => { try { f(); } catch (e) { console.error(`h9ns: ${e.message}`); } };

// No console: input is at its end and there are no signals.
const host = {
  readStdin: async () => null,
  cancelStdin: () => {},
  waitSignal: () => new Promise(() => {}),
  stopSignals: () => {},
  setRaw: () => {},
};

async function load(wasm) {
  if (wasm instanceof WebAssembly.Module || wasm instanceof ArrayBuffer || ArrayBuffer.isView(wasm)) return wasm;
  const url = new URL(wasm ?? 'h9ns.wasm', import.meta.url);
  if (url.protocol === 'file:') {
    const { readFile } = await import('node:fs/promises');
    return new Uint8Array(await readFile(url));
  }
  const r = await fetch(url, { cache: 'no-cache' });
  if (!r.ok) throw new Error(`${url}: ${r.status} ${r.statusText}`);
  return new Uint8Array(await r.arrayBuffer());
}

async function start({ wasm, maxMemory, ports: given = {} }) {
  for (const [name, port] of Object.entries(given)) portOp(() => ports.add(name, port));
  const h9 = await load(wasm);
  const dec = new TextDecoder();
  const done = run({
    h9: h9 instanceof WebAssembly.Module ? h9 : new Uint8Array(h9.buffer ?? h9, h9.byteOffset ?? 0, h9.byteLength),
    wasi: (memory) => wasiImports({
      memory,
      root: parseRoot(new TextEncoder().encode('h9root1\n')),
      args: ['h9ns'],
      env: {},
      write: (fd, data) => console.error(dec.decode(data).replace(/\n$/, '')),
    }),
    host,
    ports,
    maxMemory,
    log: (m) => console.error(m),
  });
  post({ type: 'started' });
  return done;
}

listen((m) => {
  switch (m.type) {
    case 'start':
      start(m).then(
        (code) => post({ type: 'exit', code }),
        (e) => post({ type: 'error', message: e instanceof Panic ? `h9ns: panic: ${e.message}` : String(e?.stack ?? e) }),
      );
      break;
    case 'add-port': portOp(() => ports.add(m.name, m.port)); break;
    case 'remove-port': ports.remove(m.name); break;
    case 'connect': portOp(() => ports.serve(m.port, m.aname ?? '')); break;
  }
});
