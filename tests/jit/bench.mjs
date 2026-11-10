// Measures the wasm emitter's modules in V8: how long a batch of N random
// regions takes to compile (and, with lazy compilation, to compile on first
// call) in each tier, and how fast a counted loop runs.
//
//   node tests/jit/bench.mjs path/to/jit-runtime.wasm
//
// It runs itself under four V8 configurations: the default (lazy, Liftoff
// first, TurboFan for hot functions), and eagerly in Liftoff only and in
// TurboFan only.

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { importedTableSize, wasmJit } from '../../src/web/h9-web.js';

const configs = {
  default: [],
  'liftoff, eager': ['--liftoff-only', '--no-wasm-lazy-compilation'],
  'turbofan, eager': ['--no-liftoff', '--no-wasm-lazy-compilation'],
};

if (!process.env.BENCH_CHILD) {
  const self = new URL(import.meta.url).pathname;
  for (const [name, flags] of Object.entries(configs)) {
    const out = execFileSync(process.execPath, [...flags, self, process.argv[2]], { env: { ...process.env, BENCH_CHILD: '1' } });
    console.log(`${name}:\n${out}`);
  }
  process.exit(0);
}

const bytes = readFileSync(process.argv[2]);
const table = new WebAssembly.Table({ element: 'anyfunc', initial: importedTableSize(bytes) ?? 0 });
const rt = (await WebAssembly.instantiate(bytes, { env: { __indirect_function_table: table } })).instance.exports;
const jit = wasmJit({ memory: rt.memory, table, exports: () => rt });
rt.case_count();
const status = rt.status_alloc(1);
const base = table.length;
const install = async (len, n) => {
  jit.jit_compile(rt.module_ptr(), len, base, n, status);
  await jit.settled();
  if (new Int32Array(rt.memory.buffer, status, 1)[0] !== 1) throw new Error('install failed');
};

for (const [layout, brTable] of [['a function each', 0], ['br_table', 1]]) {
  console.log(`  ${layout}:`);
  for (const n of [1, 10, 100, 1000]) {
    rt.fuzz_reset(n, n);
    const len = rt.fuzz_emit(0, n, 1, brTable ? 2 : 0);
    const t0 = performance.now();
    await install(len, n);
    const t1 = performance.now();
    // A first call compiles its function when compilation is lazy.
    table.get(base)(rt.bench_ctx());
    const t2 = performance.now();
    console.log(`  ${String(n).padStart(6)} regions, ${(len / 1024).toFixed(1).padStart(6)} KiB: install ${(t1 - t0).toFixed(1)} ms, first call ${(t2 - t1).toFixed(1)} ms`);
    jit.jit_drop(base, n);
  }
}

// How fast a counted loop runs, alone and as one region of a batch of
// 1000: per call of 200k iterations, until it's been fast for a while.
const iters = 200_000;
for (const [name, len] of [
  ['alone', () => rt.bench_prepare()],
  ['in a batch of 1000, a function each', () => rt.bench_batch(1000, 0)],
  ['in a batch of 1000, br_table', () => rt.bench_batch(1000, 1)],
]) {
  await install(len(), name === 'alone' ? 1 : 1000);
  const start = performance.now();
  const samples = [];
  while (performance.now() - start < 3000) {
    const t0 = performance.now();
    if (!rt.bench_run(base, iters)) throw new Error('loop gave the wrong sum');
    samples.push([t0 - start, (performance.now() - t0) * 1e6 / iters]);
  }
  const best = Math.min(...samples.map((x) => x[1]));
  const first = samples[0][1];
  const fastAt = samples.find((x) => x[1] < best * 1.3)[0];
  console.log(`  loop ${name}: ${first.toFixed(2)} ns an iteration at first, ${best.toFixed(2)} at best (${(3 / best * 1000).toFixed(0)} guest MIPS), within 30% of that after ${fastAt.toFixed(0)} ms`);
}
