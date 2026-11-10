// Runs the wasm emitter's tests (suite.mjs) under Node.
//
//   node tests/jit/run.mjs path/to/jit-runtime.wasm [seeds]

import { readFileSync } from 'node:fs';
import { runSuite } from './suite.mjs';

const ok = await runSuite(readFileSync(process.argv[2]), { seeds: Number(process.argv[3] ?? 300) });
process.exit(ok ? 0 : 1);
