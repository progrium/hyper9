// The namespace kernel with an h9 machine in Chromium
// (design/namespace-kernel.md): the page starts h9ns.wasm in one Worker
// and an h9 machine in another, whose root is a namespace the kernel
// serves over a MessagePort. The namespace's tree is root.h9a's 9front
// root, served to the kernel by a JS 9P server on the page
// (tests/web/ninep.mjs), with a fresh #O over /n. No COOP or COEP
// headers are sent.
//
//   node tests/web/nskernel-browser.mjs zig-out/nskernel zig-out/web
//
// Needs Playwright with Chromium, and `zig build web` with a 386 root for
// root.h9a; skips without them.
import { createServer } from 'node:http';
import { readFile, access } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const nsDir = path.resolve(process.argv[2] ?? 'zig-out/nskernel');
const webDir = path.resolve(process.argv[3] ?? 'zig-out/web');
const testDir = path.dirname(new URL(import.meta.url).pathname);
const skip = (why) => { console.log(`nskernel-browser: skipping: ${why}`); process.exit(0); };
let chromium;
try { ({ chromium } = require('playwright')); } catch { skip('no Playwright'); }
try { await access(path.join(webDir, 'root.h9a')); await access(path.join(webDir, 'h9.wasm')); } catch { skip(`no h9.wasm and root.h9a in ${webDir}`); }

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm' };
const server = createServer(async (req, res) => {
  const u = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (u === '/') return res.writeHead(200, { 'content-type': 'text/html' }).end('<!doctype html><title>nskernel</title>');
  const [base, rest] = u.startsWith('/ns/') ? [nsDir, u.slice(4)] : u.startsWith('/t/') ? [testDir, u.slice(3)] : [webDir, u.slice(1)];
  const p = path.join(base, rest);
  if (!p.startsWith(base)) return res.writeHead(403).end();
  try {
    const body = await readFile(p);
    res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch();
let failed = 0;
const errors = [];
const page = await browser.newPage();
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
await page.goto(url);

async function test(name, f) {
  const t0 = Date.now();
  try {
    await f();
    console.log(`ok   ${name} (${Date.now() - t0} ms)`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name}: ${e.message}${errors.length ? `\nerrors: ${errors.join('\n')}` : ''}`);
  }
}

// The kernel, its namespace for the machine, and the machine running
// `script` there. `after` runs once the machine prints `ready`.
const runMachine = (script, after) => page.evaluate(async ({ script, after }) => {
  const { createNamespaceKernel } = await import('/ns/h9ns.js');
  const { createMachine } = await import('/h9-web.js');
  const { parseRoot } = await import('/wasi-mem.js');
  const { Client, serveNodes, serveTree } = await import('/t/ninep.mjs');
  const dec = new TextDecoder();
  if (typeof SharedArrayBuffer !== 'undefined' && crossOriginIsolated) throw new Error('the page is cross-origin isolated');
  const k = await createNamespaceKernel({ wasm: '/ns/h9ns.wasm' });
  const lend = (name, serve, tree) => {
    const ch = new MessageChannel();
    serve(ch.port2, tree);
    k.addPort(name, ch.port1);
  };
  lend('root', serveNodes, parseRoot(await (await fetch('/root.h9a')).arrayBuffer()));
  lend('x', serveTree, { hello: 'hello from the page\n' });
  lend('late', serveTree, { f: 'mounted late\n' });
  const c0 = new Client(k.connect(''));
  await c0.connect('');
  const ctl = await c0.openRW('ns/clone');
  const id = dec.decode(await c0.read(ctl, 0)).trim();
  const line = (l) => c0.write(ctl, 0, `${l}\n`);
  await line('mount port!root /');
  await line("bind '#O' /n");
  const c1 = new Client(k.connect(id));
  await c1.connect(id);
  await c1.make('n/x', { dir: true });
  await c1.make('n/late', { dir: true });
  await line('mount port!x /n/x');
  let out = '';
  let ran = false;
  const m = await createMachine({
    mounts: [{ port: k.connect(id), dst: '/' }],
    terminal: {
      // Standard output; h9's warnings go to 2.
      write(d, fd) {
        if (fd !== 1) return;
        out += dec.decode(d);
        if (!ran && after && out.includes('ready\n')) {
          ran = true;
          line(after).catch((e) => { out += `ctl: ${e.message}\n`; });
        }
      },
    },
  });
  const code = await Promise.race([m.run(['rc', '-c', script]), new Promise((res) => setTimeout(() => res('timed out'), 90_000))]);
  m.terminate();
  k.terminate();
  return { code, out };
}, { script, after });

await test('an h9 machine runs ls /n/x with its root served by the namespace kernel [namespace-kernel, port-streams]', async () => {
  const { code, out } = await runMachine('ls /n/x; cat /n/x/hello');
  if (code !== 0 || out !== '/n/x/hello\nhello from the page\n') throw new Error(`exit ${code}, output ${JSON.stringify(out)}`);
});

await test('a bind written after a machine starts is seen by it [namespace-kernel, port-streams]', async () => {
  const { code, out } = await runMachine('test -e /n/late/f && echo early; echo ready; while(! test -e /n/late/f) sleep 1; cat /n/late/f', 'mount port!late /n/late');
  if (code !== 0 || out !== 'ready\nmounted late\n') throw new Error(`exit ${code}, output ${JSON.stringify(out)}`);
});

await browser.close();
server.close();
process.exit(failed ? 1 : 0);
