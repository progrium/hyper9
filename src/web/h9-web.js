// h9's JS host (design/0012-browser-host.md): instantiates v86.wasm and
// h9.wasm on one memory, runs h9's coroutines on JavaScript Promise
// Integration, and passes v86's exports to h9's v86 backend
// (src/vmm/v86.zig). The same code runs under Node (h9-node) and in a
// Web Worker (worker.js), with the page's side of it in createMachine.

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

// v86 0.5.473's function table: 900 JIT slots after its own 1024
// (WASM_TABLE_SIZE and WASM_TABLE_OFFSET in src/rust/jit.rs). Pinned with
// the release in scripts/pins.sh.
const V86_TABLE_SIZE = 1924;
const V86_TABLE_OFFSET = 1024;

// v86's memory_size register, in its register block (scripts/pins.sh).
const V86_MEMORY_SIZE = 812;

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
 *   jit_eval, jit_slow_load, jit_slow_store, jit_interp, and jit_helper as
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
          env = { memory, table, eval: x.jit_eval, slow_load: x.jit_slow_load, slow_store: x.jit_slow_store, interp: x.jit_interp, helper: x.jit_helper };
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
 * Instantiates v86 and h9 and runs h9's main with `args`. Resolves to the
 * exit code.
 *
 * - h9, v86: the modules' bytes (or WebAssembly.Module).
 * - wasi(memory): the wasi_snapshot_preview1 imports, over `memory`.
 * - host: the console and signals, as functions:
 *   readStdin(n) -> Promise<Uint8Array|null|'cancelled'>, cancelStdin(),
 *   waitSignal() -> Promise<number>, stopSignals(), setRaw(on).
 * - stats({ maxStack }): called once h9 ends, with the deepest any
 *   coroutine's stack got at a park, in bytes.
 */
export async function run({ h9, v86, wasi, host, log = console.error, stats }) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  const h9mod = h9 instanceof WebAssembly.Module ? h9 : new WebAssembly.Module(h9);
  const v86mod = v86 instanceof WebAssembly.Module ? v86 : new WebAssembly.Module(v86);
  const h9pages = importedMemoryPages(h9 instanceof WebAssembly.Module ? new Uint8Array(0) : h9);
  // h9's own function table, which the JIT installs regions in.
  const h9tableSize = h9 instanceof WebAssembly.Module ? null : importedTableSize(h9);

  // v86, first: it owns the memory's low part (its register block, data
  // and stack), and h9 is linked to start at 16 MiB.
  const table = new WebAssembly.Table({ element: 'anyfunc', initial: V86_TABLE_SIZE });
  let vx, mem;
  const pending = [];
  const jitImports = Object.create(null);
  const str = (p, n) => new TextDecoder().decode(new Uint8Array(mem.buffer, p >>> 0, n >>> 0));
  const none = () => 0;
  const venv = {
    __indirect_function_table: table,
    microtick: () => performance.now(),
    // No devices, so no timers to run.
    run_hardware_timers: () => 100,
    // The backend learns of a halt from main_loop returning.
    cpu_event_halt: () => {},
    stop_idling: () => {},
    get_rand_int: () => crypto.getRandomValues(new Uint32Array(1))[0],
    console_log_from_wasm: (p, n) => log('v86: ' + str(p, n)),
    // A guest at ring 3 can't reach ports or MMIO.
    io_port_read8: none, io_port_read16: none, io_port_read32: none,
    io_port_write8: none, io_port_write16: none, io_port_write32: none,
    mmap_read8: none, mmap_read32: none,
    mmap_write8: none, mmap_write16: none, mmap_write32: none, mmap_write64: none, mmap_write128: none,
    jit_clear_func: (i) => table.set(i + V86_TABLE_OFFSET, null),
    codegen_finalize: (idx, start, flags, ptr, len) => {
      // A Worker, and Node, may compile synchronously.
      const code = new Uint8Array(mem.buffer, ptr >>> 0, len >>> 0).slice();
      const inst = new WebAssembly.Instance(new WebAssembly.Module(code), { e: jitImports });
      table.set(idx + V86_TABLE_OFFSET, inst.exports.f);
      // v86 panics if this is called from inside codegen_finalize.
      pending.push([idx, start, flags]);
    },
  };
  const vinst = new WebAssembly.Instance(v86mod, { env: venv });
  vx = vinst.exports;
  mem = vx.memory;
  jitImports.m = mem;
  for (const k of Object.keys(vx)) if (!(k.startsWith('_') || k.startsWith('zstd') || k.endsWith('_js'))) jitImports[k] = vx[k];
  vx.rust_init();
  if (h9pages > mem.buffer.byteLength / PAGE) mem.grow(h9pages - mem.buffer.byteLength / PAGE);

  let guest = 0, guestSize = 0;
  const v86imports = {
    // Guest RAM: one allocation, made once h9's heap has its start
    // (design/0012-browser-host.md, "One memory").
    init: (size) => {
      size >>>= 0;
      if (guest === 0) {
        new Uint32Array(mem.buffer, V86_MEMORY_SIZE, 1)[0] = size;
        guest = vx.allocate_memory(size) >>> 0;
        guestSize = size;
      }
      return size <= guestSize ? guest : 0;
    },
    main_loop: () => {
      vx.main_loop();
      while (pending.length) vx.codegen_finalize_finished(...pending.shift());
    },
    reset_cpu: vx.reset_cpu,
    full_clear_tlb: vx.full_clear_tlb,
    update_state_flags: vx.update_state_flags,
    get_eflags: vx.get_eflags,
    jit_dirty_cache: vx.jit_dirty_cache,
  };

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
  };
  const wimports = wasi(mem);
  wimports.proc_exit = (code) => { throw new Exit(code); };
  const inst = new WebAssembly.Instance(h9mod, {
    env: { memory: mem, ...(h9table ? { __indirect_function_table: h9table } : {}) },
    wasi_snapshot_preview1: wimports,
    h9: h9imports,
    v86: v86imports,
  });
  hx = inst.exports;
  entry = WebAssembly.promising(hx.h9_coro_entry);
  // _start is the first coroutine, on the linker's stack.
  WebAssembly.promising(hx._start)().then(() => finish(0), die);
  if (!stats) return done;
  return done.finally(() => stats({ maxStack: Number(hx.h9_coro_maxdepth()) }));
}

// WebSockets for src/hstream.zig (design/0021-websocket-9p.md, "On the
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

// The h9 flags for a policy object, which takes Policy's fields under
// their CLI names: profile, write, net, memory, timeout, pids, cpus,
// readable, writable and readDeny (lists), env (an object), strict.
function policyFlags(policy = {}) {
  const f = [];
  const one = { profile: '--profile', write: '--write', net: '--net', memory: '--memory', timeout: '--timeout', pids: '--pids', cpus: '--cpus' };
  for (const [k, flag] of Object.entries(one)) if (policy[k] !== undefined) f.push(`${flag}=${policy[k]}`);
  const many = { readable: '--readable', writable: '--writable', readDeny: '--read-deny' };
  for (const [k, flag] of Object.entries(many)) for (const v of policy[k] ?? []) f.push(flag, v);
  for (const [k, v] of Object.entries(policy.env ?? {})) f.push('--env', `${k}=${v}`);
  if (policy.strict) f.push('--strict');
  return f;
}

/**
 * A machine in its own Worker (design/0012-browser-host.md), from the
 * page:
 *
 * - root: the root archive's URL (default root.h9a beside this file), or
 *   a ws:// or wss:// URL of a 9P server (design/0021-websocket-9p.md)
 * - memory: --memory, such as '256M'
 * - policy: see policyFlags
 * - terminal: { write(bytes, fd), setRaw(on) }, where the console goes
 * - tty: the terminal is one to Linux programs (isatty, termios and raw
 *   mode), as a host terminal is; for a terminal that handles raw mode
 *
 * machine.run(argv) runs h9 with the flags and argv (['rc', '-i'], say)
 * and resolves to its exit status. machine.input(bytes or string) types,
 * machine.interrupt() is the interrupt key, and machine.terminate() ends
 * the Worker.
 */
export async function createMachine({ root, memory, policy, terminal, tty = false } = {}) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration');
  const worker = new Worker(new URL('worker.js', import.meta.url), { type: 'module' });
  const enc = new TextEncoder();
  let started = false;
  return {
    run(argv) {
      if (started) return Promise.reject(new Error('a machine runs once'));
      started = true;
      const flags = [...(memory ? [`--memory=${memory}`] : []), ...policyFlags(policy)];
      return new Promise((resolve, reject) => {
        worker.onmessage = ({ data: m }) => {
          switch (m.type) {
            case 'output': terminal?.write(m.data, m.fd); break;
            case 'raw': terminal?.setRaw?.(m.on); break;
            case 'exit': resolve(m.code); worker.terminate(); break;
            case 'error': reject(new Error(m.message)); worker.terminate(); break;
          }
        };
        worker.onerror = (e) => reject(new Error(e.message));
        worker.postMessage({ type: 'start', argv: [...flags, ...argv], root: root && String(new URL(root, location.href)), tty });
      });
    },
    input(data) {
      if (data === null) { worker.postMessage({ type: 'input', data: null }); return; }
      const b = typeof data === 'string' ? enc.encode(data) : new Uint8Array(data);
      worker.postMessage({ type: 'input', data: b }, [b.buffer]);
    },
    interrupt() { worker.postMessage({ type: 'interrupt' }); },
    terminate() { worker.terminate(); },
  };
}
