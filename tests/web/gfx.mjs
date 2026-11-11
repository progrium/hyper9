// Graphics on the browser host (design/browser-gfx.md) in Chromium:
// serves zig-out/web and a test page beside it, and runs machines with a
// canvas through createMachine. Each case is named as the proposal names
// it, with the proposal's tag, [browser-gfx].
//
//     node tests/web/gfx.mjs [zig-out/web]
//
// Needs Playwright with Chromium, and `zig build web` with a 386 root for
// root.h9a (with rio and acme, from src/web/root.list).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const dir = path.resolve(process.argv[2] ?? 'zig-out/web');

// The draw fixture's messages (tests/fixtures/gfx/draw.S): 'b' allocates
// a 1x1 replicated opaque red image, 'd' draws it at (10,10)-(60,60) of
// the screen, image 0, and 'v' flushes.
function drawMessages() {
  const b = [];
  const byte = (v) => b.push(v & 0xff);
  const word = (v) => { for (let i = 0; i < 4; i++) b.push((v >>> (8 * i)) & 0xff); };
  byte(0x62); word(1); word(0); byte(0); word(0x08182848); byte(1);
  for (const v of [0, 0, 1, 1, -0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF]) word(v);
  word(0xFF0000FF);
  byte(0x64); for (const v of [0, 1, 1, 10, 10, 60, 60, 0, 0, 0, 0]) word(v);
  byte(0x76);
  return Uint8Array.from(b);
}

// root.h9a with test files added: entries appended to the archive
// (tools/webroot.zig's format) replace or add to what's there.
async function testArchive() {
  const base = await readFile(path.join(dir, 'root.h9a'));
  const files = {
    'tmp/drawmsg': drawMessages(),
    // A draw client: reads /dev/draw/new's first field, its client id,
    // writes the messages to its data file, and keeps the client open
    // while the page looks.
    'tmp/draw': new TextEncoder().encode(
      '#!/bin/rc\n' +
      '{ x=`{dd -bs 144 -count 1 >[2]/dev/null}; cat /tmp/drawmsg >/dev/draw/$x(1)^/data; echo drawn; sleep 30 } <>/dev/draw/new\n'),
  };
  const parts = [base];
  for (const [p, data] of Object.entries(files)) {
    const name = new TextEncoder().encode(p);
    const h = Buffer.alloc(4 + name.length + 8);
    h.writeUInt32LE(name.length, 0);
    Buffer.from(name).copy(h, 4);
    h.writeUInt32LE(0o100775, 4 + name.length);
    h.writeUInt32LE(data.length, 8 + name.length);
    parts.push(h, Buffer.from(data));
  }
  return Buffer.concat(parts);
}

// The test page: a canvas, an input outside it, and window.start(opts,
// argv), which runs a machine and collects its console output, its exit,
// and its snarf events.
const testPage = `<!doctype html>
<meta charset="utf-8">
<link rel="icon" href="data:,">
<style>body { margin: 0 } #c { display: block; width: 640px; height: 480px } #outside { margin: 8px }</style>
<canvas id="c"></canvas>
<input id="outside" value="">
<script type="module">
import { createMachine } from './h9-web.js';
const dec = new TextDecoder();
window.t = { out: '', snarfs: [], code: undefined, error: undefined, m: null };
window.start = async (gfx, argv) => {
  const m = await createMachine({ root: 'root-test.h9a', gfx: { canvas: document.getElementById('c'), ...gfx },
    terminal: { write: (b) => { t.out += dec.decode(b, { stream: true }); } } });
  t.m = m;
  m.addEventListener('snarf', (e) => t.snarfs.push(e.text));
  m.run(argv).then((c) => { t.code = c; }, (e) => { t.error = e.message; });
};
window.ready = true;
</script>`;

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const archive = await testArchive();
const server = createServer(async (req, res) => {
  const name = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (name === '/gfx-test.html') return res.writeHead(200, { 'content-type': 'text/html' }).end(testPage);
  if (name === '/root-test.h9a') return res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(archive);
  let p = path.join(dir, name);
  if (p.endsWith('/')) p += 'index.html';
  try {
    const body = await readFile(p);
    res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 800, height: 600 }, deviceScaleFactor: 1 });
await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: url.slice(0, -1) });
let failed = 0;

// A fresh page for each case, with its machine started.
async function machine(gfx, argv) {
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(url + 'gfx-test.html');
  await page.waitForFunction(() => window.ready);
  await page.evaluate(([g, a]) => window.start(g, a), [gfx, argv]);
  const state = () => page.evaluate(() => ({ out: t.out, snarfs: t.snarfs, code: t.code, error: t.error }));
  // Waits until f(state) is true.
  const until = async (what, f, ms = 60_000) => {
    const end = Date.now() + ms;
    for (;;) {
      const s = await state();
      if (s.error) throw new Error(`${what}: the run failed: ${s.error}`);
      if (f(s)) return s;
      if (Date.now() > end) throw new Error(`waiting for ${what}; console: ${JSON.stringify(s.out)}; errors: ${errors.join('\n')}`);
      await page.waitForTimeout(100);
    }
  };
  return { page, until, errors };
}

// The canvas's pixels, from a screenshot of it: { w, h, at(x, y) } with
// at giving 0xRRGGBB.
async function canvasPixels(page) {
  const png = await page.locator('#c').screenshot();
  return page.evaluate(async (b64) => {
    const img = new Image();
    img.src = `data:image/png;base64,${b64}`;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.width;
    c.height = img.height;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0);
    return { w: img.width, h: img.height, px: Array.from(g.getImageData(0, 0, img.width, img.height).data) };
  }, png.toString('base64')).then(({ w, h, px }) => ({
    w, h, at: (x, y) => (px[(y * w + x) * 4] << 16) | (px[(y * w + x) * 4 + 1] << 8) | px[(y * w + x) * 4 + 2],
  }));
}

async function test(name, f) {
  const t0 = Date.now();
  try {
    await f();
    console.log(`ok: ${name} (${Date.now() - t0} ms)`);
  } catch (e) {
    console.error(`FAIL: ${name}: ${e.message}`);
    failed++;
  }
}

const field = (s, i) => s.slice(i * 12, i * 12 + 12).trim();

try {
  await test('a draw client\'s image reaches the canvas [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['/tmp/draw']);
    await until('the draw', (s) => s.out.includes('drawn'));
    let px;
    for (let i = 0; i < 50; i++) {
      await page.waitForTimeout(100);
      px = await canvasPixels(page);
      if (px.at(10, 10) === 0xff0000) break;
    }
    const want = [[10, 10, true], [59, 59, true], [5, 5, false], [60, 60, false]];
    for (const [x, y, red] of want) {
      if ((px.at(x, y) === 0xff0000) !== red) throw new Error(`pixel ${x},${y} is ${px.at(x, y).toString(16)}`);
    }
    await page.close();
  });

  await test('rio starts, and a window\'s rc runs a command typed into it [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['rio', '-i', 'window rc']);
    await page.evaluate(() => navigator.clipboard.writeText(''));
    const c = page.locator('#c');
    await c.focus();
    // Keys typed before rio reads /dev/kbd are dropped, so the line is
    // typed again until the clipboard, or the snarf event, has it.
    const end = Date.now() + 120_000;
    let got = '';
    for (let n = 0; Date.now() < end; n++) {
      if (n % 30 === 0) await page.keyboard.type('echo hi > /dev/snarf\n');
      await page.waitForTimeout(100);
      const s = await page.evaluate(async () => ({ clip: await navigator.clipboard.readText(), snarfs: t.snarfs }));
      got = s.snarfs.at(-1) ?? s.clip;
      if (got === 'hi\n') break;
    }
    if (got !== 'hi\n') throw new Error(`the clipboard has ${JSON.stringify(got)}`);
    await page.close();
  });

  await test('a paste into the canvas reaches /dev/snarf [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['rc', '-c', 'echo ready; x=(); while(~ $#x 0){ sleep 1; x=`{cat /dev/snarf} }; echo snarf: $x']);
    await until('ready', (s) => s.out.includes('ready'));
    await page.evaluate(() => navigator.clipboard.writeText('pasted text'));
    await page.locator('#c').focus();
    await page.keyboard.press('ControlOrMeta+V');
    await until('the snarf buffer', (s) => s.out.includes('snarf: pasted text'));
    await page.close();
  });

  await test('resizing the canvas resizes the screen [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['rc', '-c',
      'for(i in `{seq 40}){ dd -bs 144 -count 1 </dev/draw/new >[2]/dev/null; echo; sleep 1 }']);
    const sizes = (s) => s.out.split('\n').filter((l) => l.length >= 144).map((l) => `${field(l, 6)}x${field(l, 7)}`);
    await until('the first size', (s) => sizes(s).length > 0);
    const first = sizes(await until('', () => true)).at(0);
    if (first !== '640x480') throw new Error(`the screen starts at ${first}`);
    await page.evaluate(() => { const c = document.getElementById('c'); c.style.width = '800px'; c.style.height = '500px'; });
    await until('800x500', (s) => sizes(s).includes('800x500'));
    await page.close();
  });

  await test('keys typed outside the canvas don\'t reach /dev/kbd [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['rc', '-c', 'echo ready; cat /dev/kbd']);
    await until('ready', (s) => s.out.includes('ready'));
    await page.waitForTimeout(1000);
    await page.locator('#outside').focus();
    await page.keyboard.type('x');
    await page.locator('#c').focus();
    await page.keyboard.type('y');
    const s = await until('the key typed in the canvas', (s) => s.out.includes('cy\0'));
    if (s.out.includes('x')) throw new Error(`/dev/kbd read ${JSON.stringify(s.out)}`);
    if ((await page.locator('#outside').inputValue()) !== 'x') throw new Error('the input outside lost its key');
    await page.close();
  });

  await test('machine.hangup posts hangup and ends the run [browser-gfx]', async () => {
    const { page, until } = await machine({ scale: 1 }, ['rc', '-c', 'echo ready; sleep 100']);
    await until('ready', (s) => s.out.includes('ready'));
    const t0 = Date.now();
    await page.evaluate(() => t.m.hangup());
    const s = await until('the run to end', (s) => s.code !== undefined, 20_000);
    if (s.code === 0) throw new Error('the run exited 0');
    if (Date.now() - t0 > 15_000) throw new Error('the run took too long to end');
    await page.close();
  });
} finally {
  await browser.close();
  server.close();
}
process.exit(failed ? 1 : 0);
