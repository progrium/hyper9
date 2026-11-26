// Runs a Zig test binary built for wasm32-wasi under Node's WASI, and
// exits with its status. build.zig's sched-test runs the scheduler's
// cases this way (design/scheduler.md), after Binaryen's Asyncify pass.
//
//   node --no-warnings tests/web/wasi-test.mjs test.wasm

import { readFileSync } from 'node:fs';
import { WASI } from 'node:wasi';

const wasi = new WASI({ version: 'preview1', args: ['test'], env: {}, returnOnExit: true });
const mod = await WebAssembly.compile(readFileSync(process.argv[2]));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
process.exitCode = wasi.start(inst);
