// h9's JS host (design/epoch-0/browser-host.md): instantiates h9.wasm, runs
// its coroutines on JavaScript Promise Integration, and compiles the
// modules its JIT builds (wasmJit). The same code runs under Node
// (h9-node) and in a Web Worker (worker.js), with the page's side of it in
// createMachine.

import { openStatic, StaticTree, Session } from './statictree.js';

/** Whether this JS engine has JSPI, which h9 needs. */
export const haveJSPI = typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';

const isNode = typeof process !== 'undefined' && !!process.versions?.node;

/** The guest program's exit, thrown through wasm by proc_exit. */
export class Exit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}

/** A fatal error in h9 itself: a kernel panic, a trap or a stack overflow. */
export class Panic extends Error {}

const PAGE = 65536;

/**
 * The minimum size, in wasm pages, of the memory a module imports, read
 * from its import section, or 0 if it imports none.
 */
export function importedMemoryPages(bytes) {
  return importedMin(bytes, 2) ?? 0;
}

/**
 * The minimum size of the function table a module imports (h9.wasm
 * imports its own, so the JIT can grow it), or null if it imports none.
 */
export function importedTableSize(bytes) {
  return importedMin(bytes, 1);
}

// The minimum of the first import of `want` kind (1 table, 2 memory).
function importedMin(bytes, want) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let i = 8;
  const leb = () => {
    let r = 0, s = 0, x;
    do { x = b[i++]; r |= (x & 0x7f) << s; s += 7; } while (x & 0x80);
    return r >>> 0;
  };
  const skipName = () => { const n = leb(); i += n; };
  const limits = () => { const f = leb(); const min = leb(); if (f & 1) leb(); return min; };
  while (i < b.length) {
    const id = b[i++];
    const size = leb();
    const end = i + size;
    if (id === 2) {
      for (let n = leb(); n > 0; n--) {
        skipName();
        skipName();
        const kind = b[i++];
        if (kind === 0) leb();
        else if (kind === 1) { i++; const m = limits(); if (want === 1) return m; }
        else if (kind === 2) { const m = limits(); if (want === 2) return m; }
        else if (kind === 3) i += 2;
        else if (kind === 4) { i++; leb(); }
      }
      return null;
    }
    i = end;
  }
  return null;
}

/**
 * The JIT's side of the host (src/engine/hcpu/jit/emit/wasm.zig): compiles the modules
 * h9's JIT builds in its memory, asynchronously, and installs their
 * regions in h9's function table. h9 calls a region there through a
 * function pointer, and regions tail-call each other through it.
 *
 * - memory and table: h9's memory and the function table it imports.
 * - exports(): h9's exports, once it's instantiated. Modules import its
 *   jit_eval, jit_slow_load, jit_slow_store, jit_interp, jit_helper,
 *   jit_slow_cas, and jit_ext as
 *   they are, so no JS frame sits between a region and h9 and JSPI can
 *   suspend through both.
 *
 * Returns h9's imports, and settled() for tests, a Promise for every
 * compile started since the last call:
 *
 * - jit_compile(ptr, len, base, n, status): copies the module at
 *   ptr..ptr+len, compiles it off the thread, installs its exports r0 to
 *   r{n-1} at table slots base to base+n-1 (growing the table to fit; the
 *   slots are null until then), and sets the i32 at `status` to 1, or to
 *   -1 if it failed or the slots were dropped first. h9 keeps interpreting
 *   until it sees 1.
 * - jit_drop(base, n): nulls those slots and cancels a compile still on
 *   its way to them. h9 unlinks the chain cells that point at them first.
 */
export function wasmJit({ memory, table, exports, log = console.error }) {
  let env = null;
  const pending = new Map(); // base -> the compile that owns it
  let started = [];
  const setStatus = (at, v) => { new Int32Array(memory.buffer, at >>> 0, 1)[0] = v; };
  return {
    jit_compile(ptr, len, base, n, status) {
      base >>>= 0;
      n >>>= 0;
      if (table.length < base + n) table.grow(base + n - table.length);
      const bytes = new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0).slice();
      const token = {};
      pending.set(base, token);
      started.push(WebAssembly.compile(bytes).then((mod) => {
        if (!env) {
          const x = exports();
          env = { memory, table, eval: x.jit_eval, slow_load: x.jit_slow_load, slow_store: x.jit_slow_store, interp: x.jit_interp, helper: x.jit_helper, slow_cas: x.jit_slow_cas, ext: x.jit_ext };
        }
        return WebAssembly.instantiate(mod, { env: { ...env, base: new WebAssembly.Global({ value: 'i32' }, base) } });
      }).then((inst) => {
        if (pending.get(base) !== token) return setStatus(status, -1);
        pending.delete(base);
        for (let k = 0; k < n; k++) table.set(base + k, inst.exports[`r${k}`]);
        setStatus(status, 1);
      }, (e) => {
        if (pending.get(base) === token) pending.delete(base);
        log(`jit: ${e.message}`);
        setStatus(status, -1);
      }));
    },
    jit_drop(base, n) {
      base >>>= 0;
      pending.delete(base);
      for (let k = 0; k < n >>> 0; k++) table.set(base + k, null);
    },
    settled() {
      const all = started;
      started = [];
      return Promise.all(all);
    },
  };
}

// Runs fn on a later turn of the event loop. setTimeout(0) is clamped to
// 4 ms after a few nested calls, which would throttle every yield.
const nextTask = (() => {
  if (typeof setImmediate === 'function') return (fn) => setImmediate(fn);
  const ch = new MessageChannel();
  const q = [];
  ch.port1.onmessage = () => q.shift()();
  return (fn) => { q.push(fn); ch.port2.postMessage(0); };
})();

/**
 * Instantiates h9 and runs h9's main with `args`. Resolves to the
 * exit code.
 *
 * - h9: the module's bytes (or WebAssembly.Module).
 * - wasi(memory): the wasi_snapshot_preview1 imports, over `memory`.
 * - host: the console and signals, as functions:
 *   readStdin(n) -> Promise<Uint8Array|null|'cancelled'>, cancelStdin(),
 *   waitSignal() -> Promise<number>, stopSignals(), setRaw(on).
 * - stats({ maxStack }): called once h9 ends, with the deepest any
 *   coroutine's stack got at a park, in bytes.
 * - gfx: a GfxHost, the page's canvas in a Worker
 *   (design/epoch-0/browser-gfx.md); without one, --gfx fails as on a build
 *   without graphics.
 * - credentials(url, failed, helper): called before each WebSocket
 *   handshake h9 makes, a root's or a namespace file's mount
 *   (design/epoch-0/credential-helpers.md, "Web host"). `failed` is null, or
 *   why the last try failed, for a retry; `helper` is the matching
 *   `--cred` helper's command as an array, or undefined. It returns (or
 *   resolves to) null for no credential, header lines (a string or an
 *   array of `Name: value` strings), or `{ url, headers }`, where `url`
 *   is a URL to connect to instead, such as one with a single-use ticket
 *   in its query. A browser's WebSocket can't send headers, so there only
 *   `url` works. Throwing fails the handshake with the error's message.
 * - ports: the machine's MessagePorts (design/epoch-0/port-streams.md), a Ports
 *   or an object from names to ports, which `port!NAME` and
 *   `port://NAME` name; and its served ports, from Ports.serve.
 */
export async function run({ h9, wasi, host, log = console.error, stats, gfx, credentials, ports, maxMemory }) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  const h9mod = h9 instanceof WebAssembly.Module ? h9 : new WebAssembly.Module(h9);
  const h9pages = importedMemoryPages(h9 instanceof WebAssembly.Module ? new Uint8Array(0) : h9);
  // h9's own function table, which the JIT installs regions in.
  const h9tableSize = h9 instanceof WebAssembly.Module ? null : importedTableSize(h9);

  // h9's memory: wasm32's 4 GiB at most, grown by h9's allocator and the
  // emulator's arena.
  // maxMemory, in bytes, caps it lower.
  const maxPages = maxMemory ? Math.max(h9pages, 1, Math.min(65536, Math.ceil(maxMemory / 65536))) : 65536;
  const mem = new WebAssembly.Memory({ initial: Math.max(h9pages, 1), maximum: maxPages });
  const str = (p, n) => new TextDecoder().decode(new Uint8Array(mem.buffer, p >>> 0, n >>> 0));

  // Coroutines. A park is a Promise that unpark resolves; an unpark
  // before the park leaves a permit, so the park returns at once.
  const waiters = new Map();
  const permits = new Set();
  let fatal = null;
  let finish;
  const done = new Promise((res) => { finish = res; });
  const die = (e) => {
    if (fatal) return;
    fatal = e;
    finish(e instanceof Exit ? e.code : Promise.reject(e));
  };
  let entry, hx;
  const h9table = h9tableSize === null ? null : new WebAssembly.Table({ element: 'anyfunc', initial: h9tableSize });
  const jit = h9table && wasmJit({ memory: mem, table: h9table, exports: () => hx, log });
  const h9imports = {
    park: new WebAssembly.Suspending((id, ms) => {
      if (permits.delete(id)) return 1;
      return new Promise((res) => {
        let t = null;
        if (ms >= 0) t = setTimeout(() => { waiters.delete(id); res(0); }, ms);
        waiters.set(id, () => { if (t !== null) clearTimeout(t); res(1); });
      });
    }),
    unpark: (id) => {
      const w = waiters.get(id);
      if (w) { waiters.delete(id); w(); } else permits.add(id);
    },
    start: (c) => nextTask(() => entry(c).catch(die)),
    yield: new WebAssembly.Suspending(() => new Promise((res) => nextTask(res))),
    sleep: new WebAssembly.Suspending((ms) => new Promise((res) => setTimeout(res, ms))),
    panic: (p, n) => { throw new Panic(str(p, n)); },
    random: (p, n) => { crypto.getRandomValues(new Uint8Array(mem.buffer, p >>> 0, n >>> 0)); },
    now_ms: () => Date.now(),
    mono_ms: () => performance.now(),
    read_stdin: new WebAssembly.Suspending(async (p, n) => {
      const got = await host.readStdin(n >>> 0);
      if (got === 'cancelled') return -2;
      if (got === null) return 0;
      if (got === undefined) return -1;
      new Uint8Array(mem.buffer, p >>> 0, got.length).set(got);
      return got.length;
    }),
    cancel_stdin: () => host.cancelStdin(),
    wait_signal: new WebAssembly.Suspending(() => host.waitSignal()),
    stop_signals: () => host.stopSignals(),
    set_raw: (on) => host.setRaw(!!on),
    ...wsImports(() => mem, str, credentials, ports instanceof Ports ? ports : new Ports(ports)),
    ...(jit ? { jit_compile: jit.jit_compile, jit_drop: jit.jit_drop } : {}),
    ...(gfx ?? noGfx).imports(() => mem),
  };
  const wimports = wasi(mem);
  wimports.proc_exit = (code) => { throw new Exit(code); };
  const inst = new WebAssembly.Instance(h9mod, {
    env: { memory: mem, ...(h9table ? { __indirect_function_table: h9table } : {}) },
    wasi_snapshot_preview1: wimports,
    h9: h9imports,
  });
  hx = inst.exports;
  // Table slots from here on are the JIT's (src/engine/hcpu/jit/wasm_t1.zig).
  if (h9table && hx.jit_table_base) hx.jit_table_base(h9table.length);
  entry = WebAssembly.promising(hx.h9_coro_entry);
  // _start is the first coroutine, on the linker's stack.
  WebAssembly.promising(hx._start)().then(() => finish(0), die);
  if (!stats) return done;
  return done.finally(() => stats({ maxStack: Number(hx.h9_coro_maxdepth()) }));
}

// WebSockets for src/hstream.zig (design/epoch-0/websocket-9p.md, "On the
// web host"): the page's WebSocket, or Node's, does the handshake,
// TLS and framing. ws_opened and ws_recv are Suspending: each parks only
// the stream's reader coroutine.
// Whether this host's WebSocket takes handshake headers: Node's does, as
// an option a browser's doesn't have.
const wsHeaders = typeof process !== 'undefined' && !!process.versions?.node;

// A credentials callback's answer as ws_cred's text: `url URL` first, if
// it gave one, then header lines.
function credText(r) {
  if (r == null) return null;
  const lines = (h) => (h == null ? [] : Array.isArray(h) ? h : String(h).split('\n')).map((l) => l.trim()).filter((l) => l);
  if (typeof r === 'object' && !Array.isArray(r)) return [...(r.url ? [`url ${r.url}`] : []), ...lines(r.headers)].join('\n');
  return lines(r).join('\n');
}

// Ports (design/epoch-0/port-streams.md): a MessagePort carries one 9P
// connection, one 9P message per message, in an ArrayBuffer that's
// transferred. h9 opens a port by name with port_open, which makes an
// entry in the WebSockets' table, so ws_recv, ws_send, ws_close,
// ws_status, and ws_free work on it as on a socket; port_accept hands
// h9 the next port the page serves the machine on.
const portName = /^[A-Za-z0-9._-]+$/;
const maxPortMessage = 16 << 20;

/**
 * A machine's ports, by name. A name is letters, digits, `-`, `_`, and
 * `.`. A port h9 hasn't opened can be replaced; one it has can't, and is
 * opened once: a closed one stays spent until it's removed or replaced.
 */
export class Ports {
  constructor(init) {
    this.map = new Map();
    this.served = [];
    this.serveWait = null;
    this.stopped = false;
    // Whether the machine serves on ports, and with /net: set before it
    // starts (createMachine's serve and serveNet).
    this.serving = false;
    this.serveNet = false;
    if (init instanceof Map) for (const [k, v] of init) this.add(k, v);
    else for (const [k, v] of Object.entries(init ?? {})) this.add(k, v);
  }

  /** Adds `port` as `name`, replacing a port h9 hasn't opened. */
  add(name, port) {
    if (typeof name !== 'string' || !portName.test(name)) throw new Error(`port ${JSON.stringify(name)}: a name is letters, digits, -, _, and .`);
    if (!port || typeof port.postMessage !== 'function') throw new Error(`port ${name}: not a MessagePort`);
    if (this.map.get(name)?.state === 'open') throw new Error(`port ${name}: in use`);
    this.map.set(name, { port, state: 'ready', sock: null });
  }

  /** The first free name of the form `mountN`. */
  freeName(prefix = 'mount') {
    for (let i = 0; ; i++) if (!this.map.has(`${prefix}${i}`)) return `${prefix}${i}`;
  }

  /** Removes `name`, hanging up whatever uses it. */
  remove(name) {
    const e = this.map.get(name);
    if (!e) return false;
    this.map.delete(name);
    if (e.sock) e.sock.end(1001, 'port removed', true);
    else try { e.port.close(); } catch {}
    return true;
  }

  /**
   * Hands `port` to the machine to serve (port_accept). `aname` is the
   * attach name the namespace kernel fixes for it (port_aname).
   */
  serve(port, aname = '') {
    if (!port || typeof port.postMessage !== 'function') throw new Error('serve: not a MessagePort');
    this.served.push({ port, aname: String(aname) });
    const w = this.serveWait;
    this.serveWait = null;
    w?.();
  }

  /** Ends port_accept's wait, as the machine ends. */
  stop() {
    this.stopped = true;
    const w = this.serveWait;
    this.serveWait = null;
    w?.();
  }
}

// A socket-table entry for an opened port.
function portSock(port, poke, onEnd) {
  const s = { port, q: [], cur: null, off: 0, open: 1, closed: false, code: 0, reason: '', err: '', waiter: null, session: null, protocol: '' };
  // Ends the stream: posts the hangup (null) to the far end unless it
  // ended it, and closes the port, which can't be opened again.
  s.end = (code, reason, hangup) => {
    if (s.closed) return;
    s.closed = true;
    s.code = code;
    s.reason = reason;
    if (hangup) try { port.postMessage(null); } catch {}
    port.onmessage = null;
    try { port.close(); } catch {}
    onEnd?.();
    poke(s);
  };
  port.onmessage = ({ data }) => {
    if (s.closed) return;
    if (data === null) return s.end(1000, '', false);
    const b = data instanceof ArrayBuffer ? new Uint8Array(data)
      : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : null;
    // As a WebSocket text frame on a 9P stream: the stream closes.
    if (!b) return s.end(1003, "a message that isn't binary", true);
    if (b.length > maxPortMessage) return s.end(1009, 'a message over 16 MiB', true);
    s.q.push({ text: false, b });
    poke(s);
  };
  // Node fires close when the other end closes, is collected, or its
  // Worker ends; browsers that have it do too.
  const gone = () => s.end(1006, "the port's other end closed", false);
  if (typeof port.on === 'function') port.on('close', gone);
  else port.addEventListener?.('close', gone);
  return s;
}

function wsImports(memory, str, credentials, ports) {
  const socks = new Map();
  let next = 1;
  const enc = new TextEncoder();
  const u8 = (p, n) => new Uint8Array(memory().buffer, p >>> 0, n >>> 0);
  const setU32 = (p, v) => new DataView(memory().buffer).setUint32(p >>> 0, v, true);
  // Resolves the socket's waiter, if a coroutine is parked on it.
  const poke = (s) => { const w = s.waiter; s.waiter = null; w?.(); };
  const until = (s, ready) => (ready() ? null : new Promise((res) => { s.waiter = res; }));
  const addSock = (s) => {
    const id = next++;
    socks.set(id, s);
    return id;
  };
  return {
    // A port's id in the table; -1 if there's no port by that name, -2
    // if it's in use, -3 if it has been opened and closed.
    port_open: (np, nn) => {
      const name = str(np, nn);
      const e = ports.map.get(name);
      if (!e) return -1;
      if (e.state === 'open') return -2;
      if (e.state === 'done') return -3;
      e.state = 'open';
      const s = portSock(e.port, poke, () => { e.state = 'done'; e.sock = null; });
      e.sock = s;
      return addSock(s);
    },
    // The next port the page serves the machine on, opened; -1 once the
    // machine stops serving.
    port_accept: new WebAssembly.Suspending(async () => {
      for (;;) {
        if (ports.stopped) return -1;
        const e = ports.served.shift();
        if (e) {
          const s = portSock(e.port, poke);
          s.aname = e.aname;
          return addSock(s);
        }
        await new Promise((res) => { ports.serveWait = res; });
      }
    }),
    // An accepted port's attach name, copied to p, n bytes at most: its
    // length, or -1 if it doesn't fit or there's no such port.
    port_aname: (id, p, n) => {
      const s = socks.get(id);
      if (!s) return -1;
      const b = enc.encode(s.aname ?? '');
      if (b.length > n >>> 0) return -1;
      u8(p, b.length).set(b);
      return b.length;
    },
    port_stop: () => ports.stop(),
    port_serving: () => (ports.serving ? 1 : 0) | (ports.serveNet ? 2 : 0),
    ws_cred: new WebAssembly.Suspending(async (up, un, fp, fn, ap, an, op, on) => {
      const helper = an ? str(ap, an).split('\n') : undefined;
      const put = (t) => {
        const b = enc.encode(t);
        if (b.length >= on) return false;
        u8(op, b.length).set(b);
        return b.length;
      };
      const fail = (m) => { put(`${m}\0`) === false && put('credentials: error\0'); return -2; };
      if (!credentials) return helper ? fail(`credential helper ${helper[0].split('/').pop()}: this host runs no helpers`) : -1;
      let t;
      try {
        t = credText(await credentials(str(up, un), fn ? str(fp, fn) : null, helper));
      } catch (e) {
        return fail(e?.message ?? String(e));
      }
      if (t == null) return -1;
      const n = put(t);
      return n === false ? fail('credentials: answer too long') : n;
    }),
    ws_open: (up, un, pp, pn, hp, hn, st) => {
      let w;
      const url = str(up, un);
      try {
        const protocols = pn ? str(pp, pn).split(',') : [];
        const headers = {};
        for (const l of hn ? str(hp, hn).split('\n') : []) {
          const c = l.indexOf(':');
          if (c > 0) headers[l.slice(0, c).trim()] = l.slice(c + 1).trim();
        }
        if (Object.keys(headers).length && !wsHeaders) return -2;
        w = Object.keys(headers).length ? new WebSocket(url, { protocols, headers }) : new WebSocket(url, protocols);
      } catch {
        return -1;
      }
      w.binaryType = 'arraybuffer';
      const s = { w, q: [], cur: null, off: 0, open: 0, closed: false, code: 0, reason: '', err: '', waiter: null, session: null, protocol: '' };
      w.onopen = () => { s.open = 1; poke(s); };
      w.onerror = () => { s.err = 'connection failed'; };
      w.onmessage = (e) => {
        s.q.push(typeof e.data === 'string' ? { text: true, b: enc.encode(e.data) } : { text: false, b: new Uint8Array(e.data) });
        poke(s);
      };
      w.onclose = (e) => {
        // An http(s) URL whose server didn't upgrade may be a static
        // tree, served here (src/web/statictree.js).
        if (st && s.open === 0 && !s.session) {
          s.session = 'probing';
          const http = url.replace(/^ws(s?):/, 'http$1:');
          openStatic(http).then((t) => {
            if (t instanceof StaticTree) {
              s.session = new Session(t);
              s.protocol = '9p';
              s.open = 1;
            } else {
              s.closed = true;
              s.code = 1006;
              s.reason = `no WebSocket and no static tree (${t.message})`;
              s.open = -1;
            }
            poke(s);
          });
          return;
        }
        s.closed = true;
        s.code = e.wasClean ? e.code : 1006;
        s.reason = e.wasClean ? e.reason : (s.err || e.reason || 'connection failed');
        if (s.open === 0) s.open = -1;
        poke(s);
      };
      const id = next++;
      socks.set(id, s);
      return id;
    },
    ws_opened: new WebAssembly.Suspending(async (id, p, n) => {
      const s = socks.get(id);
      if (!s) return -1;
      await until(s, () => s.open !== 0);
      if (s.open < 0) return -1;
      const b = enc.encode(s.session ? s.protocol : s.w.protocol).subarray(0, n);
      u8(p, b.length).set(b);
      return b.length;
    }),
    ws_recv: new WebAssembly.Suspending(async (id, p, n, infop) => {
      const s = socks.get(id);
      if (!s) return -1;
      for (;;) {
        if (!s.cur && s.q.length) { s.cur = s.q.shift(); s.off = 0; }
        if (s.cur?.text) {
          const b = s.cur.b;
          const take = Math.min(n, b.length - s.off);
          u8(p, take).set(b.subarray(s.off, s.off + take));
          s.off += take;
          const fin = s.off >= b.length;
          if (fin) s.cur = null;
          setU32(infop, 1 | (fin ? 2 : 0));
          return take;
        }
        if (s.cur) {
          // Binary data is a byte stream: take as many queued binary
          // messages as fit, since a server may send many small ones.
          let got = 0;
          while (s.cur && !s.cur.text && got < n) {
            const b = s.cur.b;
            const take = Math.min(n - got, b.length - s.off);
            u8(p + got, take).set(b.subarray(s.off, s.off + take));
            s.off += take;
            got += take;
            if (s.off >= b.length) { s.cur = s.q.shift() ?? null; s.off = 0; }
          }
          setU32(infop, 2);
          return got;
        }
        if (s.closed) return -1;
        await until(s, () => s.q.length > 0 || s.closed);
      }
    }),
    ws_send: (id, kind, p, n) => {
      const s = socks.get(id);
      if (s?.port) {
        if (s.closed || kind) return -1;
        // Its own buffer, transferred: one 9P message per message.
        const b = u8(p, n).slice();
        try { s.port.postMessage(b.buffer, [b.buffer]); } catch { return -1; }
        return 0;
      }
      if (s?.session instanceof Session) {
        if (s.closed) return -1;
        s.session.feed(u8(p, n).slice(), (r) => { s.q.push({ text: false, b: r }); poke(s); });
        return 0;
      }
      if (!s || s.w.readyState !== 1) return -1;
      const b = u8(p, n).slice();
      s.w.send(kind ? new TextDecoder().decode(b) : b);
      return 0;
    },
    ws_close: (id, code, p, n) => {
      const s = socks.get(id);
      if (s?.port) { s.end(1000, '', true); return; }
      if (s?.session instanceof Session) {
        s.closed = true;
        s.code = 1000;
        poke(s);
        return;
      }
      if (!s || s.w.readyState >= 2) return;
      // A page may only send 1000 or 3000 to 4999.
      try { s.w.close(code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000, str(p, n)); } catch { s.w.close(); }
    },
    ws_status: (id, p, n, lenp) => {
      const s = socks.get(id);
      if (!s) return 1006;
      const b = enc.encode(s.reason).subarray(0, n);
      u8(p, b.length).set(b);
      setU32(lenp, b.length);
      return s.closed ? s.code : 0;
    },
    ws_free: (id) => {
      const s = socks.get(id);
      if (!s) return;
      if (s.port) { s.end(1000, '', true); socks.delete(id); return; }
      if (s.w.readyState < 2) s.w.close();
      socks.delete(id);
    },
  };
}

// Graphics (design/epoch-0/browser-gfx.md). src/kern/gfx-web.c's imports:
// the screen is in wasm memory, and the host copies changed rectangles
// onto an OffscreenCanvas once a frame; the page's input waits in a queue
// for gfxinput, a kernel process, to take with gfx_wait.

/** The events gfx_wait hands to gfx-web.c, four ints each. */
export const GfxEv = { key: 1, mouse: 2, resize: 3, paste: 4 };

// A host with no canvas: h9-node, or a page that passed no gfx option.
const noGfx = {
  imports: () => ({
    gfx_present: () => 0,
    gfx_size: () => {},
    gfx_screen: () => {},
    gfx_flush: () => {},
    gfx_wait: new WebAssembly.Suspending(async () => 0),
    gfx_paste: () => 0,
    gfx_snarf: () => {},
    gfx_cursor: () => {},
  }),
};

/** Whether this JS engine can draw on an OffscreenCanvas from a Worker. */
export function canDrawInWorker() {
  return typeof OffscreenCanvas === 'function' && typeof requestAnimationFrame === 'function';
}

/**
 * The canvas's side of a machine, in its Worker: `canvas` is the
 * OffscreenCanvas the page transferred, `width` and `height` the screen's
 * size in its pixels, and `post` sends the page the cursor and the snarf
 * buffer ({ type: 'cursor', data } and { type: 'snarf', text }). The page's
 * events go in through `input`, `paste` and `resize`.
 */
export class GfxHost {
  constructor({ canvas, width, height, post }) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false });
    if (!this.ctx) throw new Error("this browser can't draw from a Worker");
    this.size = [width | 0, height | 0];
    this.post = post;
    this.screen = null; // { base, stride, dx, dy }, in wasm memory
    this.dirty = null;  // [minx, miny, maxx, maxy]
    this.framing = false;
    this.q = [];        // events, four ints each
    this.pastes = [];   // pasted texts, as UTF-8
    this.waiter = null;
    this.memory = null;
    this.raf = typeof requestAnimationFrame === 'function' ? (f) => requestAnimationFrame(f) : (f) => setTimeout(f, 16);
  }

  #push(...ev) {
    this.q.push(ev);
    const w = this.waiter;
    this.waiter = null;
    w?.();
  }

  /** A key (rune, down) or the pointer (x, y, Plan 9 buttons). */
  input(ev) {
    if (Array.isArray(ev) && ev.length === 4) this.#push(ev[0] | 0, ev[1] | 0, ev[2] | 0, ev[3] | 0);
  }

  /** Text pasted into the canvas, which replaces the snarf buffer. */
  paste(text) {
    const b = new TextEncoder().encode(String(text));
    this.pastes.push(b);
    this.#push(GfxEv.paste, b.length, 0, 0);
  }

  /** The canvas's new size, in the screen's pixels. */
  resize(width, height) {
    this.size = [width | 0, height | 0];
    this.#push(GfxEv.resize, width | 0, height | 0, 0);
  }

  // Copies the dirty rectangle of the screen onto the canvas, with each
  // pixel's X byte set to 255, outside any coroutine.
  #frame() {
    this.framing = false;
    const s = this.screen, d = this.dirty;
    this.dirty = null;
    if (!s || !d) return;
    const [x0, y0] = [Math.max(0, d[0]), Math.max(0, d[1])];
    const [x1, y1] = [Math.min(s.dx, d[2]), Math.min(s.dy, d[3])];
    const w = x1 - x0, h = y1 - y0;
    if (w <= 0 || h <= 0) return;
    const src = new Uint8Array(this.memory().buffer);
    const img = new ImageData(w, h);
    const px = img.data;
    for (let y = 0; y < h; y++) {
      const at = s.base + (y0 + y) * s.stride + x0 * 4;
      px.set(src.subarray(at, at + w * 4), y * w * 4);
    }
    const u = new Uint32Array(px.buffer);
    for (let i = 0; i < u.length; i++) u[i] |= 0xff000000;
    this.ctx.putImageData(img, x0, y0);
  }

  #mark(r) {
    const d = this.dirty;
    this.dirty = d ? [Math.min(d[0], r[0]), Math.min(d[1], r[1]), Math.max(d[2], r[2]), Math.max(d[3], r[3])] : r;
    if (!this.framing) {
      this.framing = true;
      this.raf(() => this.#frame());
    }
  }

  imports(memory) {
    this.memory = memory;
    const u8 = (p, n) => new Uint8Array(memory().buffer, p >>> 0, n >>> 0);
    return {
      gfx_present: () => 1,
      gfx_size: (p) => { new Int32Array(memory().buffer, p >>> 0, 2).set(this.size); },
      gfx_screen: (base, stride, dx, dy) => {
        this.screen = { base: base >>> 0, stride, dx, dy };
        if (this.canvas.width !== dx || this.canvas.height !== dy) {
          this.canvas.width = dx;
          this.canvas.height = dy;
        }
        this.#mark([0, 0, dx, dy]);
      },
      gfx_flush: (x0, y0, x1, y1) => this.#mark([x0, y0, x1, y1]),
      gfx_wait: new WebAssembly.Suspending(async (p, n) => {
        while (!this.q.length) await new Promise((res) => { this.waiter = res; });
        const k = Math.min(this.q.length, (n / 4) | 0);
        const out = new Int32Array(memory().buffer, p >>> 0, k * 4);
        for (let i = 0; i < k; i++) out.set(this.q.shift(), i * 4);
        return k * 4;
      }),
      gfx_paste: (p, n) => {
        const b = this.pastes.shift();
        if (!b) return 0;
        const take = Math.min(n, b.length);
        u8(p, take).set(b.subarray(0, take));
        return take;
      },
      gfx_snarf: (p, n) => this.post({ type: 'snarf', text: new TextDecoder().decode(u8(p, n)) }),
      gfx_cursor: (p) => this.post({ type: 'cursor', data: p ? u8(p, 72).slice() : null }),
    };
  }
}

// The h9 flags for a policy object, which takes Policy's fields under
// their CLI names: profile, write, net, memory, timeout, pids, cpus,
// readable, writable, and readDeny (lists), and env (an object).
/**
 * A mount for createMachine (design/epoch-0/mounts.md): { kind, src, dst, opts },
 * from a flag's string or an object. An object's `up: true` is the `up`
 * option (design/epoch-0/upper-layers.md). A `port` source (design/epoch-0/port-streams.md)
 * is a port's name or a MessagePort, which is added to `ports` (an object
 * from names to ports) under the next free `mountN`; either way it's
 * `--url port://NAME`.
 */
export function mountOf(m, ports = {}) {
  if (m && typeof m === 'object' && !(m instanceof URL) && m.port !== undefined && m.port !== false) {
    let name = m.port;
    if (typeof name !== 'string') {
      if (typeof name?.postMessage !== 'function') throw new Error('mount: port is a name or a MessagePort');
      let i = 0;
      while (`mount${i}` in ports) i++;
      ports[`mount${i}`] = name;
      name = `mount${i}`;
    }
    return mountOf({ ...m, port: undefined, url: `port://${name}` });
  }
  const kinds = ['archive', 'url', 'dir', 'builtin', 'tmp'];
  if (typeof m === 'string') {
    const f = m.match(/^--(archive|url|dir|builtin|tmp)(?:[ =](.*))?$/s);
    if (!f) throw new Error(`mount ${JSON.stringify(m)}: not --archive, --url, --dir, --builtin, or --tmp`);
    const kind = f[1], arg = f[2] ?? '';
    if (kind === 'builtin' || kind === 'tmp') {
      const [dst = '', ...rest] = arg.split(':');
      return { kind, src: '', dst, opts: rest.join(':') };
    }
    const at = dstStart(arg);
    if (at < 0) return { kind, src: arg, dst: '', opts: '' };
    const tail = arg.slice(at + 1);
    const c = tail.indexOf(':');
    return { kind, src: arg.slice(0, at), dst: c < 0 ? tail : tail.slice(0, c), opts: c < 0 ? '' : tail.slice(c + 1) };
  }
  if (m instanceof URL) return { kind: 'archive', src: String(m), dst: '', opts: '' };
  const kind = kinds.find((k) => m[k] !== undefined && m[k] !== false);
  if (!kind) throw new Error(`mount ${JSON.stringify(m)}: no archive, url, dir, builtin, or tmp`);
  const src = kind === 'builtin' || kind === 'tmp' ? '' : String(m[kind]);
  const list = Array.isArray(m.opts) ? [...m.opts] : m.opts ? [m.opts] : [];
  // `up: true` makes it the writable layer over what's beneath it
  // (design/epoch-0/upper-layers.md), as the `up` option does.
  if (m.up && !list.some((o) => /(^|,)(up|upper)(,|$)/.test(o))) list.push('up');
  return { kind, src, dst: m.dst ?? '', opts: list.join(',') };
}

// Where DST starts in a mount flag's value: the last `:` before `/` or `#`,
// except a URL's `://` (as src/mount.zig's dstStart); -1 if there's none.
function dstStart(arg) {
  const sch = arg.match(/^[A-Za-z0-9+.-]+(?=:\/\/)/);
  for (let i = arg.length - 2; i >= 0; i--) {
    if (arg[i] !== ':' || (arg[i + 1] !== '/' && arg[i + 1] !== '#')) continue;
    if (sch && i === sch[0].length) continue;
    return i;
  }
  return -1;
}

/** A mount's flag for h9's argv, its source given as `src`. */
export function mountFlag(m, src = m.src) {
  const kind = m.kind === 'archive' ? 'dir' : m.kind;
  const parts = kind === 'builtin' || kind === 'tmp' ? [] : [src];
  if (m.dst || m.opts) parts.push(m.dst || '/');
  if (m.opts) parts.push(m.opts);
  return parts.length ? `--${kind}=${parts.join(':')}` : `--${kind}`;
}

// Plans (design/plan-format.md) on the page: createMachine({ plan }) gives
// h9 the text as a file for --plan, with its archive lines' sources
// fetched as the mounts' are.

const mountKinds = ['archive', 'url', 'dir', 'builtin', 'tmp'];

/**
 * A plan's lines as h9 splits them (src/policy.zig's parsePlan and
 * src/newns.zig's split): a line that starts with `#` is a comment to its
 * end, a `#` that starts a word is one to the next `;`, `'` quotes, `''`
 * is a quote in quotes, and `;` or a newline ends a line. Each is
 * { start, end, words }, `start` and `end` its offsets in `text`.
 */
export function planLines(text) {
  const lines = [];
  let i = 0;
  while (i < text.length) {
    const eol = text.indexOf('\n', i) < 0 ? text.length : text.indexOf('\n', i);
    if (/^[ \t\r]*#/.test(text.slice(i, eol))) { i = eol + 1; continue; }
    let start = i, words = [];
    const end = () => { if (words.length) lines.push({ start, end: i, words }); words = []; };
    while (i < eol) {
      const c = text[i];
      if (c === ' ' || c === '\t' || c === '\r') { i++; if (!words.length) start = i; continue; }
      if (c === ';') { end(); i++; start = i; continue; }
      if (c === '#') {
        const semi = text.indexOf(';', i);
        if (semi < 0 || semi > eol) { i = eol; break; }
        end(); i = semi + 1; start = i; continue;
      }
      let w = '', quoted = false;
      for (; i < eol; i++) {
        const ch = text[i];
        if (ch === "'") {
          if (quoted && text[i + 1] === "'") { w += "'"; i++; } else quoted = !quoted;
          continue;
        }
        if (!quoted && (ch === ' ' || ch === '\t' || ch === '\r' || ch === ';')) break;
        w += ch;
      }
      if (quoted) throw new Error('plan: a quote that isn\'t closed');
      words.push(w);
    }
    end();
    i = eol + 1;
  }
  return lines;
}

/** A word as a plan writes it: quoted if it has to be. */
export function planWord(w) {
  return w !== '' && /^[^\s'#;]+$/.test(w) ? w : `'${w.replaceAll("'", "''")}'`;
}

/** Whether a plan has a mount line: dir, url, archive, builtin, or tmp. */
export function planHasMounts(text) {
  return planLines(text).some((l) => mountKinds.includes(l.words[0]));
}

/**
 * `text` with each `archive VALUE` line's source replaced by what
 * `f(src, index)` returns, `index` counting the archive lines; the line
 * becomes `kind` (`dir`, for a tree unpacked into the Worker's files) if
 * given. A value is a mount flag's (src/mount.zig): SRC:DST:OPTS, or the
 * long form src=…,dst=…. Other lines, and line numbers, are unchanged.
 */
export function mapPlanArchives(text, f, kind = 'archive') {
  const lines = planLines(text).filter((l) => l.words[0] === 'archive' && l.words.length === 2);
  let out = '', at = 0;
  lines.forEach((l, i) => {
    const v = l.words[1];
    let src, rest, long = false;
    const lf = v.match(/^src=("(?:[^"]|"")*"|[^,]*)/);
    if (lf) {
      long = true;
      src = lf[1].startsWith('"') ? lf[1].slice(1, -1).replaceAll('""', '"') : lf[1];
      rest = v.slice(lf[0].length);
    } else {
      const d = dstStart(v);
      src = d < 0 ? v : v.slice(0, d);
      rest = d < 0 ? '' : v.slice(d);
    }
    const s = f(src, i);
    const nv = long ? `src=${/[,"]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s}${rest}` : s + rest;
    out += text.slice(at, l.start) + `${kind} ${planWord(nv)}`;
    at = l.end;
  });
  return out + text.slice(at);
}

function policyFlags(policy = {}) {
  const f = [];
  const one = { profile: '--profile', write: '--write', net: '--net', memory: '--memory', timeout: '--timeout', pids: '--pids', cpus: '--cpus' };
  for (const [k, flag] of Object.entries(one)) if (policy[k] !== undefined) f.push(`${flag}=${policy[k]}`);
  const many = { readable: '--readable', writable: '--writable', readDeny: '--read-deny' };
  for (const [k, flag] of Object.entries(many)) for (const v of policy[k] ?? []) f.push(flag, v);
  for (const [k, v] of Object.entries(policy.env ?? {})) f.push('--env', `${k}=${v}`);
  return f;
}

// The page's side of a canvas (design/epoch-0/browser-gfx.md).

// KeyboardEvent.key's named keys, as keyboard.h's runes.
const KF = 0xF000, Spec = 0xF800;
const namedKeys = {
  Enter: 0x0a, Backspace: 0x08, Tab: 0x09, Escape: 0x1b, Delete: 0x7f,
  Home: KF | 0x0D, ArrowUp: KF | 0x0E, ArrowDown: Spec | 0x00, PageUp: KF | 0x0F,
  ArrowLeft: KF | 0x11, ArrowRight: KF | 0x12, PageDown: KF | 0x13, Insert: KF | 0x14,
  Alt: KF | 0x15, Shift: KF | 0x16, Control: KF | 0x17, End: KF | 0x18, PrintScreen: KF | 0x10,
  ScrollLock: KF | 0x19, CapsLock: Spec | 0x64, NumLock: Spec | 0x65, AltGraph: Spec | 0x67, Meta: Spec | 0x68,
  F1: KF | 1, F2: KF | 2, F3: KF | 3, F4: KF | 4, F5: KF | 5, F6: KF | 6,
  F7: KF | 7, F8: KF | 8, F9: KF | 9, F10: KF | 10, F11: KF | 11, F12: KF | 12,
};

/** The Plan 9 rune for a KeyboardEvent, or null if it isn't one. */
export function keyRune(e) {
  if (e.key in namedKeys) return namedKeys[e.key];
  const cps = [...e.key];
  return cps.length === 1 ? cps[0].codePointAt(0) : null;
}

const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform ?? '');

/**
 * Plan 9's buttons (left 1, middle 2, right 4) for a PointerEvent, whose
 * `buttons` has left 1, right 2, middle 4. A left click with Alt (Option)
 * held is the middle button, and with Cmd on macOS, or Ctrl elsewhere,
 * the right, for trackpads and one-button mice.
 */
export function plan9Buttons(e) {
  const b = e.buttons;
  let p = (b & 4 ? 2 : 0) | (b & 2 ? 4 : 0);
  if (b & 1) p |= e.altKey ? 2 : (isMac ? e.metaKey : e.ctrlKey) ? 4 : 1;
  return p;
}

/**
 * The screen's size for a canvas whose content box is css (CSS pixels)
 * and dev (device pixels) wide and high: device pixels for scale 0, CSS
 * pixels for 1, and device pixels divided by N otherwise.
 */
export function screenSize(scale, css, dev) {
  if (scale === 0) return dev.map((v) => Math.max(1, Math.round(v)));
  if (scale === 1) return css.map((v) => Math.max(1, Math.round(v)));
  return dev.map((v) => Math.max(1, Math.floor(v / scale)));
}

// /dev/cursor's 72 bytes (the offset, then clr and set) as a CSS cursor:
// set bits black, clr bits white, the rest transparent.
function cssCursor(data) {
  if (!data) return '';
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const off = [dv.getInt32(0, true), dv.getInt32(4, true)];
  const c = document.createElement('canvas');
  c.width = c.height = 16;
  const g = c.getContext('2d');
  const img = g.createImageData(16, 16);
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 16; x++) {
      const bit = 0x80 >> (x & 7), at = y * 2 + (x >> 3);
      const v = data[40 + at] & bit ? 0 : data[8 + at] & bit ? 255 : -1;
      if (v < 0) continue;
      img.data.set([v, v, v, 255], (y * 16 + x) * 4);
    }
  }
  g.putImageData(img, 0, 0);
  const hot = off.map((v) => Math.min(15, Math.max(0, -v)));
  return `url(${c.toDataURL()}) ${hot[0]} ${hot[1]}, default`;
}

// Wires the canvas's events to the Worker, once the canvas is the
// Worker's. Returns what the page does with the Worker's messages.
function attachCanvas(canvas, worker, { clipboard, scale, size, events }) {
  const send = (ev) => worker.postMessage({ type: 'gfx', ev });
  if (!canvas.hasAttribute('tabindex')) canvas.tabIndex = 0;
  canvas.style.touchAction = 'none';
  let screen = size;
  let held = 0;
  const at = (e) => {
    const fx = screen[0] / (canvas.clientWidth || screen[0]);
    const fy = screen[1] / (canvas.clientHeight || screen[1]);
    return [Math.floor(e.offsetX * fx), Math.floor(e.offsetY * fy)];
  };
  const pointer = (e) => {
    held = plan9Buttons(e);
    send([GfxEv.mouse, ...at(e), held]);
  };
  canvas.addEventListener('pointerdown', (e) => {
    canvas.focus();
    canvas.setPointerCapture(e.pointerId);
    e.preventDefault();
    pointer(e);
  });
  canvas.addEventListener('pointermove', pointer);
  canvas.addEventListener('pointerup', (e) => {
    pointer(e);
    if (!e.buttons && canvas.hasPointerCapture(e.pointerId)) canvas.releasePointerCapture(e.pointerId);
  });
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  // One wheel click per line, or per 50 pixels: button 8 up, 16 down.
  let wheel = 0;
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    wheel += e.deltaMode === 1 ? e.deltaY : e.deltaMode === 2 ? e.deltaY * 3 : e.deltaY / 50;
    const xy = at(e);
    while (Math.abs(wheel) >= 1) {
      send([GfxEv.mouse, ...xy, held | (wheel < 0 ? 8 : 16)]);
      send([GfxEv.mouse, ...xy, held]);
      wheel -= Math.sign(wheel);
    }
  }, { passive: false });

  // Keys reach the guest only while the canvas has focus. Each key's
  // release sends the rune its press did, even if Shift changed in between.
  const down = new Map();
  canvas.addEventListener('keydown', (e) => {
    if (e.isComposing || e.key === 'Process' || e.key === 'Dead') return;
    // Let Ctrl-V and Cmd-V through, so the paste event fires.
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'v' && clipboard) return;
    const r = keyRune(e);
    if (r === null) return;
    e.preventDefault();
    down.set(e.code || e.key, r);
    send([GfxEv.key, r, 1, 0]);
  });
  canvas.addEventListener('keyup', (e) => {
    const k = e.code || e.key;
    const r = down.get(k) ?? keyRune(e);
    down.delete(k);
    if (r === null) return;
    e.preventDefault();
    send([GfxEv.key, r, 0, 0]);
  });
  // Text an input method composed, rune by rune.
  canvas.addEventListener('compositionend', (e) => {
    for (const ch of e.data ?? '') {
      const r = ch.codePointAt(0);
      send([GfxEv.key, r, 1, 0]);
      send([GfxEv.key, r, 0, 0]);
    }
  });
  canvas.addEventListener('blur', () => {
    for (const r of down.values()) send([GfxEv.key, r, 0, 0]);
    down.clear();
  });
  if (clipboard) {
    canvas.addEventListener('paste', (e) => {
      e.preventDefault();
      worker.postMessage({ type: 'gfx-paste', text: e.clipboardData?.getData('text/plain') ?? '' });
    });
  }

  if (typeof ResizeObserver === 'function') {
    const ro = new ResizeObserver(([ent]) => {
      const css = [ent.contentRect.width, ent.contentRect.height];
      // The device-pixel box is exact where CSS times the ratio rounds,
      // but it ignores an emulated ratio (DevTools, Playwright), so it's
      // taken only when the two agree to within a pixel.
      const est = css.map((v) => v * devicePixelRatio);
      const dpb = ent.devicePixelContentBoxSize?.[0];
      const dev = dpb && Math.abs(dpb.inlineSize - est[0]) <= 1 && Math.abs(dpb.blockSize - est[1]) <= 1 ? [dpb.inlineSize, dpb.blockSize] : est;
      const s = screenSize(scale, css, dev);
      if (s[0] === screen[0] && s[1] === screen[1]) return;
      screen = s;
      worker.postMessage({ type: 'gfx-size', width: s[0], height: s[1] });
    });
    try { ro.observe(canvas, { box: 'device-pixel-content-box' }); } catch { ro.observe(canvas); }
  }

  return (m) => {
    switch (m.type) {
      case 'cursor': canvas.style.cursor = cssCursor(m.data); return true;
      case 'snarf': {
        const fire = () => events.dispatchEvent(Object.assign(new Event('snarf'), { text: m.text }));
        if (navigator.clipboard?.writeText) navigator.clipboard.writeText(m.text).catch(fire); else fire();
        return true;
      }
    }
    return false;
  };
}

/**
 * A machine in its own Worker (design/epoch-0/browser-host.md), from the
 * page:
 *
 * - mounts: the machine's mounts (design/epoch-0/mounts.md), in order, each a
 *   flag's string, such as '--archive=linux.h9a:#L' or
 *   '--url wss://fs.example/9p:/n/fs', or an object: { archive: URL },
 *   { url: URL }, { builtin: true }, or { tmp: true }, with dst (default
 *   /) and opts ('ro', 'b', and so on, a string or a list). An archive is
 *   fetched and its tree stacked where dst says. A static tree over
 *   http:// or https:// is read with the page's fetch. With no mounts,
 *   root.h9a beside this file is the root
 * - binds: --bind lines, each 'SRC:DST[:OPTS]'
 * - memory: --memory, such as '256M'
 * - backend: --engine: 'hcpu' (h9's own CPUs, h86, ha64, and hx64, the default), or 'emu' or 'v86', its old names
 * - arch: --arch: the guest's CPU, '386' (h86, the default), 'arm64'
 *   (ha64), or 'amd64' (hx64); 'arm64' and 'amd64' run Linux programs
 *   of their architecture, such as Alpine's
 * - policy: see policyFlags
 * - terminal: { write(bytes, fd), setRaw(on) }, where the console goes
 * - tty: the terminal is one to Linux programs (isatty, termios and raw
 *   mode), as a host terminal is; for a terminal that handles raw mode
 * - gfx: { canvas, clipboard, scale }, a <canvas> for /dev/draw,
 *   /dev/mouse, /dev/cursor, and /dev/kbd (design/epoch-0/browser-gfx.md).
 *   clipboard is "page" (the default: a paste into the canvas fills
 *   /dev/snarf, and a write to it is copied to the page's clipboard) or
 *   "private" (--gfx=noclip). scale is --gfx-scale: 0 (the default)
 *   draws in device pixels, 1 in CSS pixels, and N in device pixels
 *   divided by N. The canvas moves into the Worker at run.
 * - env: h9's own environment (an object), not its programs': the
 *   emulator's knobs, such as H9_JIT_HOT (src/engine/hcpu/jit/wasm_t1.zig)
 * - ports: MessagePorts the machine can mount by name
 *   (design/epoch-0/port-streams.md), an object from names to ports, each
 *   carrying a 9P connection; a mount's source can be { port: NAME } or
 *   { port: MessagePort }, and a namespace file's `mount port!NAME`.
 *   machine.addPort(name, port) adds one while it runs, and
 *   machine.removePort(name) hangs up whatever uses one. The page makes
 *   the channels, so a port's other end can be another Worker's server
 * - serve: true, a MessagePort, or a list of them: the machine serves its
 *   namespace over 9P on each port, as --serve's connections are served
 *   (design/epoch-0/serve.md), with no listener, origin, or token;
 *   machine.serve(port) adds one while it runs, to a machine made with
 *   serve. serveNet: true exports /net with it, as --serve-net does
 * - plan: a plan's text (design/plan-format.md), which h9 runs as
 *   --plan does, in place of mounts and binds, which are then an error.
 *   An `archive` line's source is a URL, relative to the page, fetched
 *   and unpacked as a mount's is; a `url port://NAME` line names one of
 *   `ports`. A plan without mount lines gets root.h9a beside this file
 *   as its first line, so the line numbers h9 reports are one more. The
 *   other options are flags given with the plan, so they can only narrow
 *   it: memory and policy lower or remove, and gfx needs the plan's gfx
 *   window line. machine.run([]) runs the plan's run line
 * - credentials: async (url, failed, helper) => lines, the page's
 *   credential helper (design/epoch-0/credential-helpers.md), called in place
 *   of running a --cred helper, before each WebSocket handshake h9 makes:
 *   url is the URL, failed is null or why the last try failed, and helper
 *   is the matching --cred command's words, if any. It resolves to the
 *   helper's output (`url URL` and header lines) or '' for none, and a
 *   rejection fails the connection with its message. A browser can't
 *   send headers on a WebSocket, so only a `url` line works there
 *
 * machine.run(argv) runs h9 with the flags and argv (['rc', '-i'], say)
 * and resolves to its exit status. machine.input(bytes or string) types,
 * machine.interrupt() is the interrupt key, machine.hangup() posts
 * hangup, as closing a native window does, and machine.terminate() ends
 * the Worker. machine._put(path, data, mode) adds a file (bytes, an
 * ArrayBuffer, or a string) to the first archive's tree at path, relative
 * to its top, making its directories, while the machine runs or before;
 * mode defaults to 0644. It's provisional, so the underscore: a file the
 * guest has written or removed at path hides it, and there's nothing
 * without an archive. The machine is an EventTarget: with gfx, a write to
 * /dev/snarf that the page's clipboard refuses fires a `snarf` event
 * whose `text` is what was written.
 */
export async function createMachine({ mounts, binds = [], plan, memory, backend, arch, policy, terminal, tty = false, gfx, env, credentials, ports = {}, serve, serveNet = false } = {}) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  if (plan != null && (mounts || binds.length)) throw new Error('createMachine: a plan has its own mount and bind lines, so mounts and binds go in it');
  if (plan != null) {
    // Archives by URL from the page, so the Worker can fetch them.
    const root = new URL('root.h9a', import.meta.url);
    if (!planHasMounts(plan)) plan = `archive ${planWord(String(root))}\n${plan}`;
    plan = mapPlanArchives(String(plan), (src) => String(new URL(src, location.href)));
  }
  if (gfx && typeof gfx.canvas?.transferControlToOffscreen !== 'function') throw new Error("this browser can't draw from a Worker");
  const clipboard = (gfx?.clipboard ?? 'page') !== 'private';
  const scale = Math.max(0, Math.min(255, gfx?.scale ?? 0) | 0);
  const worker = new Worker(new URL('worker.js', import.meta.url), { type: 'module' });
  const enc = new TextEncoder();
  const events = new EventTarget();
  let started = false;
  // The ports the Worker gets with start, by name, and the served ones.
  const portMap = { ...ports };
  for (const name of Object.keys(portMap)) if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error(`port ${JSON.stringify(name)}: a name is letters, digits, -, _, and .`);
  const serving = serve != null && serve !== false;
  const served = !serving || serve === true ? [] : Array.isArray(serve) ? [...serve] : [serve];
  return Object.assign(events, {
    run(argv) {
      if (started) return Promise.reject(new Error('a machine runs once'));
      started = true;
      const ms = plan != null ? [] : (mounts ?? [{ archive: new URL('root.h9a', import.meta.url) }]).map((m) => mountOf(m, portMap));
      const flags = [...(backend ? ['--engine', backend] : []), ...(arch ? ['--arch', arch] : []), ...(memory ? [`--memory=${memory}`] : []), ...policyFlags(policy)];
      let onGfx = () => false;
      let start = {}, transfer = [];
      if (gfx) {
        const c = gfx.canvas;
        const css = [c.clientWidth, c.clientHeight];
        const size = screenSize(scale, css, css.map((v) => v * devicePixelRatio));
        const off = c.transferControlToOffscreen();
        start = { gfx: { canvas: off, width: size[0], height: size[1] } };
        transfer = [off];
        flags.push(clipboard ? '--gfx' : '--gfx=noclip', `--gfx-scale=${scale}`);
        onGfx = attachCanvas(c, worker, { clipboard, scale, size, events });
      }
      return new Promise((resolve, reject) => {
        worker.onmessage = ({ data: m }) => {
          if (onGfx(m)) return;
          switch (m.type) {
            case 'output': terminal?.write(m.data, m.fd); break;
            case 'cred':
              Promise.resolve()
                .then(() => credentials(m.url, m.failed, m.helper))
                .then((result) => worker.postMessage({ type: 'cred-reply', id: m.id, result: result ?? null }),
                  (e) => worker.postMessage({ type: 'cred-reply', id: m.id, error: String(e?.message ?? e) }));
              break;
            case 'raw': terminal?.setRaw?.(m.on); break;
            case 'exit': resolve(m.code); worker.terminate(); break;
            case 'error': reject(new Error(m.message)); worker.terminate(); break;
          }
        };
        worker.onerror = (e) => reject(new Error(e.message));
        const url = (u) => String(new URL(u, location.href));
        for (const m of ms) if (m.kind === 'archive' || (m.kind === 'url' && /^https?:/i.test(m.src))) m.src = url(m.src);
        const bindFlags = binds.flatMap((b) => ['--bind', b]);
        const portList = [...Object.values(portMap), ...served];
        worker.postMessage({ type: 'start', argv: [...flags, ...bindFlags, ...argv], mounts: ms, plan, tty, env, credentials: typeof credentials === 'function', ports: portMap, serve: served, serving, serveNet: !!serveNet, ...start }, [...transfer, ...portList]);
      });
    },
    addPort(name, port) {
      if (typeof name !== 'string' || !/^[A-Za-z0-9._-]+$/.test(name)) throw new Error(`port ${JSON.stringify(name)}: a name is letters, digits, -, _, and .`);
      if (!started) { portMap[name] = port; return; }
      worker.postMessage({ type: 'add-port', name, port }, [port]);
    },
    removePort(name) {
      if (!started) { delete portMap[name]; return; }
      worker.postMessage({ type: 'remove-port', name });
    },
    serve(port) {
      if (!serving) throw new Error('serve: the machine was made without serve');
      if (!started) { served.push(port); return; }
      worker.postMessage({ type: 'serve', port }, [port]);
    },
    input(data) {
      if (data === null) { worker.postMessage({ type: 'input', data: null }); return; }
      const b = typeof data === 'string' ? enc.encode(data) : new Uint8Array(data);
      worker.postMessage({ type: 'input', data: b }, [b.buffer]);
    },
    _put(path, data, mode = 0o644) {
      const b = typeof data === 'string' ? enc.encode(data) : new Uint8Array(data).slice();
      worker.postMessage({ type: 'put', path, data: b.buffer, mode: 0o100000 | (mode & 0o7777) }, [b.buffer]);
    },
    interrupt() { worker.postMessage({ type: 'interrupt' }); },
    hangup() { worker.postMessage({ type: 'hangup' }); },
    terminate() { worker.terminate(); },
  });
}
