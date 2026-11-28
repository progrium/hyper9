// Runs a Zig test binary built for wasm32-wasi under Node's WASI, and
// exits with its status. build.zig's sched-test runs the scheduler's
// cases this way (design/scheduler.md), after Binaryen's Asyncify pass.
//
//   node --no-warnings tests/web/wasi-test.mjs test.wasm
//
// Without the build runner to talk to, Zig's test runner prints every
// case to stderr, and zig build shows a step's stderr even when it
// passes, under a "failed command" line. So the runner's stderr goes to
// a file, printed only if the run fails.

import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WASI } from 'node:wasi';

const dir = mkdtempSync(join(tmpdir(), 'wasi-test-'));
const log = join(dir, 'stderr');
const fd = openSync(log, 'w');
let code = 1;
try {
  const wasi = new WASI({ version: 'preview1', args: ['test'], env: {}, returnOnExit: true, stderr: fd });
  const mod = await WebAssembly.compile(readFileSync(process.argv[2]));
  const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  code = wasi.start(inst);
} finally {
  closeSync(fd);
  if (code !== 0) process.stderr.write(readFileSync(log));
  rmSync(dir, { recursive: true, force: true });
}
process.exitCode = code;
