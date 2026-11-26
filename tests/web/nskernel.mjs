// The namespace kernel's cases on the web host (design/epoch-0/namespace-kernel.md),
// under Node 24 or later: h9ns.js starts h9ns.wasm in a worker_threads
// Worker, and the cases speak 9P2000 to it over MessagePorts with
// tests/web/ninep.mjs. The argument is zig-out/nskernel.
//
//   node tests/web/nskernel.mjs zig-out/nskernel [filter]

import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { Client, serveTree } from './ninep.mjs';

const [dir = 'zig-out/nskernel', filter = ''] = process.argv.slice(2);
if (typeof WebAssembly.Suspending !== 'function') {
  console.error('nskernel: this Node lacks JavaScript Promise Integration (Node 24 or later has it); skipping');
  process.exit(0);
}
const { createNamespaceKernel } = await import(pathToFileURL(resolve(dir, 'h9ns.js')));

// Runs one case on a kernel of its own.
let failed = 0;
async function test(name, f) {
  if (filter && !name.includes(filter)) return;
  const k = await createNamespaceKernel({ wasm: pathToFileURL(resolve(dir, 'h9ns.wasm')) });
  const t0 = performance.now();
  try {
    await Promise.race([f(k), new Promise((_, rej) => setTimeout(() => rej(new Error('timed out')), 20000))]);
    console.log(`ok   ${name} (${Math.round(performance.now() - t0)} ms)`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name}: ${e.message}`);
  } finally {
    k.terminate();
  }
}
const eq = (got, want, what) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};
const rejects = async (p, what) => {
  try { await p; } catch { return; }
  throw new Error(`${what}: succeeded`);
};

// A connection to namespace `aname`, attached.
async function attach(k, aname = '') {
  const c = new Client(k.connect(aname));
  await c.connect(aname);
  return c;
}

// A namespace made through /ns/clone on `c0`: its ctl fid and its id.
async function clone(c0) {
  const ctl = await c0.openRW('ns/clone');
  const id = new TextDecoder().decode(await c0.read(ctl, 0)).trim();
  return { id, line: (l) => c0.write(ctl, 0, `${l}\n`), close: () => c0.clunk(ctl) };
}

// A JS 9P server, as port `name`.
function lendTree(k, name, files) {
  const ch = new MessageChannel();
  serveTree(ch.port2, files);
  k.addPort(name, ch.port1);
}

await test('a port! mount in an empty namespace reads through a second attach [namespace-kernel, port-streams]', async (k) => {
  lendTree(k, 'x', { hello: 'hello from js\n', 'd/e': 'deep\n' });
  const c0 = await attach(k);
  const n = await clone(c0);
  await n.line("bind '#O' /");
  const c1 = await attach(k, n.id);
  await c1.make('a', { dir: true });
  await c1.make('a/b', { data: 'made\n' });
  await c1.make('n', { dir: true });
  await c1.make('n/x', { dir: true });
  await n.line('mount port!x /n/x');
  const c2 = await attach(k, n.id);
  eq(await c2.cat('a/b'), 'made\n', '/a/b');
  eq(await c2.ls('n/x'), ['d', 'hello'], 'ls /n/x');
  eq(await c2.cat('n/x/hello'), 'hello from js\n', '/n/x/hello');
  eq(await c2.cat('n/x/d/e'), 'deep\n', '/n/x/d/e');
  c2.close();
  c1.close();
  await n.close();
  c0.close();
});

await test('a bind written after an attach is seen through it [namespace-kernel, port-streams]', async (k) => {
  lendTree(k, 'late', { f: 'late\n' });
  const c0 = await attach(k);
  const n = await clone(c0);
  const task = await attach(k, n.id);
  await task.make('m', { dir: true });
  await rejects(task.cat('m/f'), 'before the mount');
  await n.line('mount port!late /m');
  eq(await task.cat('m/f'), 'late\n', '/m/f after the mount');
  await n.line('unmount /m');
  await rejects(task.cat('m/f'), 'after the unmount');
  task.close();
  await n.close();
  c0.close();
});

await test("a task's attach is fixed to its namespace and can't reach /ns [namespace-kernel]", async (k) => {
  const c0 = await attach(k);
  const n = await clone(c0);
  const task = new Client(k.connect(n.id));
  await rejects(task.connect('0'), 'attaching to another id');
  const task2 = await attach(k, n.id);
  await rejects(task2.ls('ns'), 'ls /ns');
  await rejects(n.line("bind '#N' /tmp"), "bind '#N'");
  task2.close();
  await n.close();
  c0.close();
});

process.exit(failed ? 1 : 0);
