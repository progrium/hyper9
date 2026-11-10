// Runs the wasm emitter's output under Node: every shared IR case against
// ir_eval, then the tracer bullet against T0. See wasm_runtime.zig.
//
//   node tests/jit/run.mjs path/to/jit-runtime.wasm

import { readFileSync } from "node:fs";

const rt = (await WebAssembly.instantiate(readFileSync(process.argv[2]), {})).instance.exports;
const env = {
  memory: rt.memory,
  eval: rt.jit_eval,
  slow_load: rt.jit_slow_load,
  slow_store: rt.jit_slow_store,
  interp: rt.jit_interp,
  helper: rt.jit_helper,
};

// What h9-web.js's h9_jit_compile will do: compile a module out of
// linear memory and instantiate it against the runtime's exports.
function compile(len) {
  const bytes = new Uint8Array(rt.memory.buffer, rt.module_ptr(), len).slice();
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), { env }).exports.run;
}

let failed = 0;
const n = rt.case_count();
if (n === 0) throw new Error("no cases");
for (let i = 0; i < n; i++) {
  const len = rt.case_prepare(i);
  if (len === 0) throw new Error(`case ${i}: emit failed`);
  const run = compile(len);
  const code = run(rt.case_reset(i));
  if (!rt.case_finish(code)) {
    failed++;
    const text = new TextDecoder().decode(new Uint8Array(rt.memory.buffer, rt.case_text(i), rt.case_text_len(i)));
    console.error(`case ${i} differs from ir_eval (exit ${code}):\n${text}`);
  }
}

const len = rt.tracer_prepare();
if (len === 0) throw new Error("tracer: T0, lifting, or ir_eval failed");
const run = compile(len);
const code = run(rt.tracer_reset());
if (!rt.tracer_finish(code)) {
  failed++;
  console.error(`tracer: wasm run differs from T0 (exit ${code}, x0 ${rt.tracer_x(0)})`);
}

if (failed) {
  console.error(`${failed} failed`);
  process.exit(1);
}
console.log(`wasm emitter: ${n} cases and the tracer bullet match`);
