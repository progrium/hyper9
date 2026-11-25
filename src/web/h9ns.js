// The namespace kernel's page side (design/namespace-kernel.md, The JS
// API): starts h9ns.wasm in a Worker (h9ns-worker.js) and hands it ports.
// Everything else, making and composing namespaces, is 9P2000 on a
// connection to namespace 0.
//
//   const k = await createNamespaceKernel({ wasm, memory });
//   k.addPort(name, port);     // a 9P server the kernel mounts as port!name
//   k.removePort(name);        // hangs up whatever uses it
//   const p = k.connect(id);   // a MessagePort served 9P, attached to id
//   k.terminate();
//
// wasm is h9ns.wasm's URL, bytes, or WebAssembly.Module, next to this
// file by default; memory caps the kernel's memory, in bytes. Ports carry
// one 9P message per message, as port-streams' do
// (design/epoch-0/port-streams.md). It runs in a browser or under Node 24
// or later, with worker_threads.

const portName = /^[A-Za-z0-9._-]+$/;
const isNode = typeof Worker === 'undefined' && typeof process !== 'undefined' && !!process.versions?.node;

/** Starts a namespace kernel; resolves once it's running. */
export async function createNamespaceKernel({ wasm, memory } = {}) {
  const url = new URL('h9ns-worker.js', import.meta.url);
  let worker, on;
  if (isNode) {
    const { Worker: NodeWorker } = await import('node:worker_threads');
    worker = new NodeWorker(url);
    on = (f) => worker.on('message', f);
  } else {
    worker = new Worker(url, { type: 'module' });
    on = (f) => { worker.onmessage = ({ data }) => f(data); };
  }
  const send = (m, t = []) => worker.postMessage(m, t);
  const events = new EventTarget();
  let ended = false;
  const end = (detail) => {
    if (ended) return;
    ended = true;
    events.dispatchEvent(Object.assign(new Event('exit'), detail));
  };
  await new Promise((resolve, reject) => {
    on((m) => {
      switch (m.type) {
        case 'started': resolve(); break;
        case 'exit': end({ code: m.code }); reject(new Error(`h9ns: exited ${m.code}`)); break;
        case 'error': end({ error: m.message }); reject(new Error(m.message)); break;
      }
    });
    if (isNode) worker.on('error', reject); else worker.onerror = (e) => reject(new Error(e.message));
    // A relative URL is the page's, not the Worker's.
    const w = wasm instanceof URL ? String(wasm)
      : typeof wasm === 'string' && typeof location !== 'undefined' ? String(new URL(wasm, location.href)) : wasm;
    send({ type: 'start', wasm: w, maxMemory: memory });
  });
  return Object.assign(events, {
    addPort(name, port) {
      if (typeof name !== 'string' || !portName.test(name)) throw new Error(`port ${JSON.stringify(name)}: a name is letters, digits, -, _, and .`);
      if (!port || typeof port.postMessage !== 'function') throw new Error(`port ${name}: not a MessagePort`);
      send({ type: 'add-port', name, port }, [port]);
    },
    removePort(name) {
      send({ type: 'remove-port', name });
    },
    connect(aname = '') {
      const ch = new MessageChannel();
      send({ type: 'connect', port: ch.port2, aname: String(aname) }, [ch.port2]);
      return ch.port1;
    },
    terminate() {
      worker.terminate();
      end({ code: null });
    },
  });
}
