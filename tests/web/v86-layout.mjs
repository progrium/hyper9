// Checks that the v86 layout pinned in scripts/pins.sh is what
// src/vmm/v86.zig and src/web/h9-web.js hardcode, and what v86.wasm
// does: node tests/web/v86-layout.mjs path/to/v86.wasm
// (design/0012-browser-host.md).
import { readFileSync } from 'node:fs';

const [wasmPath] = process.argv.slice(2);
const pins = readFileSync('scripts/pins.sh', 'utf8');
const zig = readFileSync('src/vmm/v86.zig', 'utf8');
const js = readFileSync('src/web/h9-web.js', 'utf8');
let bad = 0;
const fail = (m) => { console.error('v86-layout: ' + m); bad++; };

const pin = (n) => pins.match(new RegExp(`^${n}=(\\S+)`, 'm'))?.[1];
const regs = Object.fromEntries(
  pins.match(/^V86_REGS="([^"]*)"/m)[1].trim().split('\n').map((l) => { const [k, v] = l.split(/\s+/); return [k, +v]; }));

// The sources agree with the pins.
for (const [k, v] of Object.entries(regs)) {
  const m = zig.match(new RegExp(`const ${k} = (\\d+);`));
  if (!m || +m[1] !== v) fail(`src/vmm/v86.zig has ${k} = ${m?.[1]}, pins.sh ${v}`);
}
for (const [k, v] of [['V86_TABLE_SIZE', pin('V86_TABLE_SIZE')], ['V86_TABLE_OFFSET', pin('V86_TABLE_OFFSET')], ['V86_MEMORY_SIZE', regs.memory_size]]) {
  const m = js.match(new RegExp(`const ${k} = (\\d+);`));
  if (!m || +m[1] !== +v) fail(`src/web/h9-web.js has ${k} = ${m?.[1]}, pins.sh ${v}`);
}

// v86.wasm behaves as laid out.
const mod = new WebAssembly.Module(readFileSync(wasmPath));
const size = +pin('V86_TABLE_SIZE');
const env = new Proxy({}, { get: (_, k) => k === '__indirect_function_table' ? table : () => 0 });
// The table's size is the JIT's (WASM_TABLE_SIZE in jit.rs), which the
// module's import doesn't state; a wrong one shows in the integration cases.
const table = new WebAssembly.Table({ element: 'anyfunc', initial: size });
const x = new WebAssembly.Instance(mod, { env }).exports;
x.rust_init();
x.reset_cpu();
const i32 = (o) => new Int32Array(x.memory.buffer, o, 1);
const CS = 1;
// get_real_eip is instruction_pointer less CS's base.
i32(regs.segment_offsets + 4 * CS)[0] = 0x1000;
i32(regs.instruction_pointer)[0] = 0x1234;
if (x.get_real_eip() !== 0x234) fail(`get_real_eip is ${x.get_real_eip()}, not instruction_pointer - CS base`);
// get_seg_cs is CS's base.
if (x.get_seg_cs() !== 0x1000) fail(`get_seg_cs is ${x.get_seg_cs()}, not segment_offsets[CS]`);
// allocate_memory takes its size from memory_size and zeroes it; the
// other offsets are exercised by every integration case on v86.
i32(regs.memory_size)[0] = 1 << 20;
const p = x.allocate_memory(1 << 20) >>> 0;
if (!(p > regs.memory_size && p + (1 << 20) <= x.memory.buffer.byteLength)) fail(`allocate_memory returned ${p}`);

if (bad) process.exit(1);
console.log('v86-layout: ok');
