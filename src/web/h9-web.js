// h9's JS host (design/browser-host.md): instantiates h9.wasm, runs
// its coroutines on JavaScript Promise Integration, and compiles the
// modules its JIT builds (wasmJit). The same code runs under Node
// (h9-node) and in a Web Worker (worker.js), with the page's side of it in
// createMachine.

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
 * The JIT's side of the host (src/jit/emit/wasm.zig): compiles the modules
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
 *   (design/browser-gfx.md); without one, --gfx fails as on a build
 *   without graphics.
 */
export async function run({ h9, wasi, host, log = console.error, stats, gfx }) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  const h9mod = h9 instanceof WebAssembly.Module ? h9 : new WebAssembly.Module(h9);
  const h9pages = importedMemoryPages(h9 instanceof WebAssembly.Module ? new Uint8Array(0) : h9);
  // h9's own function table, which the JIT installs regions in.
  const h9tableSize = h9 instanceof WebAssembly.Module ? null : importedTableSize(h9);

  // h9's memory: wasm32's 4 GiB at most, grown by h9's allocator and the
  // emulator's arena.
  const mem = new WebAssembly.Memory({ initial: Math.max(h9pages, 1), maximum: 65536 });
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
    ...wsImports(() => mem, str),
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
  // Table slots from here on are the JIT's (src/jit/wasm_t1.zig).
  if (h9table && hx.jit_table_base) hx.jit_table_base(h9table.length);
  entry = WebAssembly.promising(hx.h9_coro_entry);
  // _start is the first coroutine, on the linker's stack.
  WebAssembly.promising(hx._start)().then(() => finish(0), die);
  if (!stats) return done;
  return done.finally(() => stats({ maxStack: Number(hx.h9_coro_maxdepth()) }));
}

// WebSockets for src/hstream.zig (design/websocket-9p.md, "On the
// browser host"): the page's WebSocket, or Node's, does the handshake,
// TLS and framing. ws_opened and ws_recv are Suspending: each parks only
// the stream's reader coroutine.
function wsImports(memory, str) {
  const socks = new Map();
  let next = 1;
  const enc = new TextEncoder();
  const u8 = (p, n) => new Uint8Array(memory().buffer, p >>> 0, n >>> 0);
  const setU32 = (p, v) => new DataView(memory().buffer).setUint32(p >>> 0, v, true);
  // Resolves the socket's waiter, if a coroutine is parked on it.
  const poke = (s) => { const w = s.waiter; s.waiter = null; w?.(); };
  const until = (s, ready) => (ready() ? null : new Promise((res) => { s.waiter = res; }));
  return {
    ws_open: (up, un, pp, pn) => {
      let w;
      try {
        const protocols = pn ? str(pp, pn).split(',') : [];
        w = new WebSocket(str(up, un), protocols);
      } catch {
        return -1;
      }
      w.binaryType = 'arraybuffer';
      const s = { w, q: [], cur: null, off: 0, open: 0, closed: false, code: 0, reason: '', err: '', waiter: null };
      w.onopen = () => { s.open = 1; poke(s); };
      w.onerror = () => { s.err = 'connection failed'; };
      w.onmessage = (e) => {
        s.q.push(typeof e.data === 'string' ? { text: true, b: enc.encode(e.data) } : { text: false, b: new Uint8Array(e.data) });
        poke(s);
      };
      w.onclose = (e) => {
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
      const b = enc.encode(s.w.protocol).subarray(0, n);
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
      if (!s || s.w.readyState !== 1) return -1;
      const b = u8(p, n).slice();
      s.w.send(kind ? new TextDecoder().decode(b) : b);
      return 0;
    },
    ws_close: (id, code, p, n) => {
      const s = socks.get(id);
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
      if (s.w.readyState < 2) s.w.close();
      socks.delete(id);
    },
  };
}

// Graphics (design/browser-gfx.md). src/kern/gfx-web.c's imports:
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
function policyFlags(policy = {}) {
  const f = [];
  const one = { profile: '--profile', write: '--write', net: '--net', memory: '--memory', timeout: '--timeout', pids: '--pids', cpus: '--cpus' };
  for (const [k, flag] of Object.entries(one)) if (policy[k] !== undefined) f.push(`${flag}=${policy[k]}`);
  const many = { readable: '--readable', writable: '--writable', readDeny: '--read-deny' };
  for (const [k, flag] of Object.entries(many)) for (const v of policy[k] ?? []) f.push(flag, v);
  for (const [k, v] of Object.entries(policy.env ?? {})) f.push('--env', `${k}=${v}`);
  return f;
}

// The page's side of a canvas (design/browser-gfx.md).

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
 * A machine in its own Worker (design/browser-host.md), from the
 * page:
 *
 * - root: the root archive's URL (default root.h9a beside this file,
 *   unless there are layers), or a ws:// or wss:// URL of a 9P server
 *   (design/websocket-9p.md)
 * - layers: more root archives, each a URL or { url, at }, unpacked in
 *   order over the root archive, a later file replacing an earlier one,
 *   each under its directory `at` (default /). Together they're the tree
 *   at /, h9's --root. A 9front tree layered at a Linux root's /9 is
 *   named by a second `--root /9` in argv (design/linux-personality.md)
 * - memory: --memory, such as '256M'
 * - backend: --backend: 'emu' (h9's own CPUs, h86, ha64, and hx64, the default) or 'v86', its old name
 * - arch: --arch: the guest's CPU, '386' (h86, the default), 'arm64'
 *   (ha64), or 'amd64' (hx64); 'arm64' and 'amd64' run Linux programs
 *   of their architecture, such as Alpine's
 * - policy: see policyFlags
 * - terminal: { write(bytes, fd), setRaw(on) }, where the console goes
 * - tty: the terminal is one to Linux programs (isatty, termios and raw
 *   mode), as a host terminal is; for a terminal that handles raw mode
 * - gfx: { canvas, clipboard, scale }, a <canvas> for /dev/draw,
 *   /dev/mouse, /dev/cursor, and /dev/kbd (design/browser-gfx.md).
 *   clipboard is "page" (the default: a paste into the canvas fills
 *   /dev/snarf, and a write to it is copied to the page's clipboard) or
 *   "private" (--gfx=noclip). scale is --gfx-scale: 0 (the default)
 *   draws in device pixels, 1 in CSS pixels, and N in device pixels
 *   divided by N. The canvas moves into the Worker at run.
 * - env: h9's own environment (an object), not its programs': the
 *   emulator's knobs, such as H9_JIT_HOT (src/jit/wasm_t1.zig)
 *
 * machine.run(argv) runs h9 with the flags and argv (['rc', '-i'], say)
 * and resolves to its exit status. machine.input(bytes or string) types,
 * machine.interrupt() is the interrupt key, machine.hangup() posts
 * hangup, as closing a native window does, and machine.terminate() ends
 * the Worker. machine._put(path, data, mode) adds a file (bytes, an
 * ArrayBuffer, or a string) to the root archive's tree at path, relative
 * to the root, making its directories, while the machine runs or before;
 * mode defaults to 0644. It's provisional, so the underscore: a file the
 * guest has written or removed at path hides it, and there's nothing for
 * a ws:// root. The machine is an EventTarget: with gfx, a write to
 * /dev/snarf that the page's clipboard refuses fires a `snarf` event
 * whose `text` is what was written.
 */
export async function createMachine({ root, layers = [], memory, backend, arch, policy, terminal, tty = false, gfx, env } = {}) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  if (gfx && typeof gfx.canvas?.transferControlToOffscreen !== 'function') throw new Error("this browser can't draw from a Worker");
  const clipboard = (gfx?.clipboard ?? 'page') !== 'private';
  const scale = Math.max(0, Math.min(255, gfx?.scale ?? 0) | 0);
  const worker = new Worker(new URL('worker.js', import.meta.url), { type: 'module' });
  const enc = new TextEncoder();
  const events = new EventTarget();
  let started = false;
  return Object.assign(events, {
    run(argv) {
      if (started) return Promise.reject(new Error('a machine runs once'));
      started = true;
      const flags = [...(backend ? ['--backend', backend] : []), ...(arch ? ['--arch', arch] : []), ...(memory ? [`--memory=${memory}`] : []), ...policyFlags(policy)];
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
            case 'raw': terminal?.setRaw?.(m.on); break;
            case 'exit': resolve(m.code); worker.terminate(); break;
            case 'error': reject(new Error(m.message)); worker.terminate(); break;
          }
        };
        worker.onerror = (e) => reject(new Error(e.message));
        const url = (u) => String(new URL(u, location.href));
        const layerList = layers.map((l) => (typeof l === 'object' && !(l instanceof URL) ? { url: url(l.url), at: l.at ?? '/' } : { url: url(l), at: '/' }));
        worker.postMessage({ type: 'start', argv: [...flags, ...argv], root: root && url(root), layers: layerList, tty, env, ...start }, transfer);
      });
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
