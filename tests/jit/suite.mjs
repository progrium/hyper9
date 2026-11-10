// The wasm emitter's tests, for Node (run.mjs) and Chromium (browser.mjs).
// wasm_runtime.zig plays h9.wasm's part: it owns memory and the function
// table, builds modules with the emitter, and checks runs against ir_eval.
// Modules are compiled and installed by h9-web.js's jitImports, as h9's
// would be, and the runtime calls each region through a function pointer.
//
// - Every IR case (emit/cases.zig) as a module of its own, and in batches
//   behind one br_table, plus the tracer bullet against T0.
// - Random regions (gen.zig): arbitrary control flow, structured and with
//   the dispatch-loop fallback, chained to each other within a module and
//   across modules through cells and tail calls, interrupted by the budget,
//   and unlinked when a module is dropped.

import { importedTableSize, jitImports } from '../../src/web/h9-web.js';

export async function runSuite(bytes, { log = console.log, error = console.error, seeds = 300 } = {}) {
  const table = new WebAssembly.Table({ element: 'anyfunc', initial: importedTableSize(bytes) ?? 0 });
  const rt = (await WebAssembly.instantiate(bytes, { env: { __indirect_function_table: table } })).instance.exports;
  const jit = jitImports({ memory: rt.memory, table, exports: () => rt, log: error });
  const text = (p, n) => new TextDecoder().decode(new Uint8Array(rt.memory.buffer, p, n));
  let failed = 0;
  const fail = (msg) => {
    failed++;
    if (failed <= 10) error(msg);
  };

  // Compiles the module the runtime just built (`len` bytes) into slots
  // base.., and resolves to whether it installed.
  const status = rt.status_alloc(1);
  const install = async (len, base, n) => {
    if (len === 0) throw new Error('emit failed');
    new Int32Array(rt.memory.buffer, status, 1)[0] = 0;
    jit.jit_compile(rt.module_ptr(), len, base, n, status); // len first: building may move the module
    await jit.settled();
    return new Int32Array(rt.memory.buffer, status, 1)[0] === 1;
  };
  const first = table.length;

  // Each case on its own, compiled all at once.
  const n = rt.case_count();
  if (n === 0) throw new Error('no cases');
  const statuses = rt.status_alloc(n);
  for (let i = 0; i < n; i++) {
    const len = rt.case_prepare(i);
    jit.jit_compile(rt.module_ptr(), len, first + i, 1, statuses + 4 * i);
  }
  await jit.settled();
  for (let i = 0; i < n; i++) {
    const st = new Int32Array(rt.memory.buffer, statuses, n)[i];
    if (st !== 1 || !rt.case_run(i, first + i)) fail(`case ${i} differs from ir_eval (status ${st}):\n${text(rt.case_text(i), rt.case_text_len(i))}`);
  }
  for (let i = 0; i < n; i++) jit.jit_drop(first + i, 1);

  // In batches, in both layouts.
  const B = 50;
  for (const brTable of [0, 1]) for (let at = 0; at < n; at += B) {
    const count = Math.min(B, n - at);
    if (!(await install(rt.batch_prepare(at, count, brTable), first, count))) { fail(`batch at ${at}: no install`); continue; }
    for (let i = at; i < at + count; i++) {
      if (!rt.case_run(i, first + i - at)) fail(`case ${i} in a batch at ${at} (br_table ${brTable}) differs from ir_eval:\n${text(rt.case_text(i), rt.case_text_len(i))}`);
    }
  }

  // The tracer bullet.
  if (!(await install(rt.tracer_prepare(), first, 1)) || !rt.tracer_run(first)) fail('tracer: wasm run differs from T0');

  // Random regions, in various layouts.
  const R = 6;
  // [name, modules as [first, count], chaining, fuzz_emit flags]
  const layouts = [
    ['one module, chained', [[0, R]], true, 0],
    ['a module each, chained', [...Array(R).keys()].map((k) => [k, 1]), true, 0],
    ['two modules, chained', [[0, 2], [2, R - 2]], true, 0],
    ['one module, dispatch loops', [[0, R]], true, 1],
    ['one module, unchained', [[0, R]], false, 0],
    ['one br_table module, chained', [[0, R]], true, 2],
    ['two br_table modules, chained', [[0, 3], [3, R - 3]], true, 2],
  ];
  let runs = 0;
  for (let seed = 1; seed <= seeds; seed++) {
    const [name, mods, chaining, flags] = layouts[seed % layouts.length];
    if (!rt.fuzz_reset(seed, R)) { fail(`seed ${seed}: generating failed`); continue; }
    let base = first;
    let ok = true;
    for (const [at, count] of mods) {
      const len = rt.fuzz_emit(at, count, chaining ? 1 : 0, flags);
      if (!(await install(len, base, count))) { ok = false; break; }
      rt.fuzz_installed(base);
      base += count;
    }
    if (!ok) { fail(`seed ${seed} (${name}): a module didn't build or install`); continue; }
    rt.fuzz_link();
    const check = (what) => {
      for (let start = 0; start < R; start++) for (const budget of [0x7fffffff, 1, 7]) {
        runs++;
        if (!rt.fuzz_run(start, seed * 31 + start, budget)) {
          const regions = [...Array(R).keys()].map((k) => `region ${k}:\n${text(rt.fuzz_text(k), rt.fuzz_text_len())}`).join('');
          fail(`seed ${seed} (${name}${what}): from region ${start} with budget ${budget}, wasm differs from ir_eval\n${text(rt.fuzz_diag(), rt.fuzz_diag_len())}${regions}`);
          return;
        }
      }
    };
    check('');
    if (mods.length > 1) {
      // Drop the first module: chains into it now leave.
      jit.jit_drop(first, mods[0][1]);
      rt.fuzz_dropped(0);
      rt.fuzz_link();
      check(', first module dropped');
    }
    for (let s = first; s < base; s++) table.set(s, null);
  }

  // The random runs must reach every way out, chains, and both lowerings.
  const stat = (k) => rt.fuzz_stat(k);
  const names = ['', 'chain', 'indirect', 'svc', 'brk', 'fault', 'undef', 'interrupted'];
  for (const k of [1, 2, 3, 5, 6, 7]) if (stat(k) === 0) fail(`no random run left with ${names[k]}`);
  if (stat(8) === 0 || stat(9) === 0 || stat(10) === 0) fail(`random runs: ${stat(8)} chains, ${stat(9)} structured regions, ${stat(10)} dispatch loops`);
  log(`random runs: ${names.slice(1).map((s, k) => `${stat(k + 1)} ${s}`).join(', ')}; ${stat(8)} chains taken; ${stat(9)} regions structured, ${stat(10)} dispatch loops`);

  if (failed) {
    error(`${failed} failed`);
    return false;
  }
  log(`wasm emitter: ${n} cases alone and in batches, the tracer bullet, and ${runs} runs of random regions from ${seeds} seeds match`);
  return true;
}
