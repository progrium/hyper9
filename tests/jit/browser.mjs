// Runs the wasm emitter's tests (suite.mjs) in Chromium, through
// Playwright: the same modules, compiled and installed by h9-web.js, in
// the engine the browser host runs on.
//
//   node tests/jit/browser.mjs path/to/jit-runtime.wasm [seeds]

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const root = path.resolve(new URL('../..', import.meta.url).pathname);
const runtime = path.resolve(process.argv[2]);
const seeds = Number(process.argv[3] ?? 300);
const page = `<!doctype html><script type="module">
import { runSuite } from '/tests/jit/suite.mjs';
const out = [];
const bytes = new Uint8Array(await (await fetch('/jit-runtime.wasm')).arrayBuffer());
window.done = runSuite(bytes, { seeds: ${seeds}, log: (s) => out.push(s), error: (s) => out.push('error: ' + s) })
  .then((ok) => ({ ok, out }), (e) => ({ ok: false, out: [...out, 'error: ' + (e?.stack ?? e)] }));
</script>`;
const server = createServer(async (req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  try {
    if (p === '/') return res.writeHead(200, { 'content-type': 'text/html' }).end(page);
    if (p === '/jit-runtime.wasm') return res.writeHead(200, { 'content-type': 'application/wasm' }).end(await readFile(runtime));
    // Only the files the suite imports.
    if (!/^\/(tests\/jit|src\/web)\/[\w.-]+\.(m?js)$/.test(p)) throw new Error('no');
    res.writeHead(200, { 'content-type': 'text/javascript' }).end(await readFile(path.join(root, p)));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));

const browser = await chromium.launch();
let ok = false;
try {
  const tab = await browser.newPage();
  tab.on('pageerror', (e) => console.error(`page: ${e.message}`));
  await tab.goto(`http://127.0.0.1:${server.address().port}/`);
  await tab.waitForFunction(() => window.done, null, { timeout: 30_000 });
  const r = await tab.evaluate(() => window.done);
  for (const line of r.out) (line.startsWith('error: ') ? console.error : console.log)(line);
  ok = r.ok;
  if (ok) console.log(`(in Chromium ${browser.version()})`);
} finally {
  await browser.close();
  server.close();
}
process.exit(ok ? 0 : 1);
