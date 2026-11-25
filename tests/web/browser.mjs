// The browser host's demo page in Chromium (design/epoch-0/browser-host.md):
// serves zig-out/web, opens index.html and drives rc through its terminal.
//
//     node tests/web/browser.mjs [zig-out/web]
//
// Needs Playwright with Chromium, and `zig build web` with a 386 root for
// root.h9a. With linux.h9a, it also runs the page's ?linux mode. With H9_TEST_WS_ROOT=ws://..., it also runs over that 9P
// server.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const dir = path.resolve(process.argv[2] ?? 'zig-out/web');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };
// A small root archive (tools/webroot.zig's format) for the mounts case:
// /lib/stacked, to stack over root.h9a.
function h9a(entries) {
  const parts = [Buffer.from('h9root1\n')];
  for (const [name, mode, data] of entries) {
    const n = Buffer.from(name), d = Buffer.from(data);
    const h = Buffer.alloc(12 + n.length);
    h.writeUInt32LE(n.length, 0);
    n.copy(h, 4);
    h.writeUInt32LE(mode, 4 + n.length);
    h.writeUInt32LE(d.length, 8 + n.length);
    parts.push(h, d);
  }
  return Buffer.concat(parts);
}
const stack = h9a([['lib', 0o40775, ''], ['lib/stacked', 0o100644, 'stacked\n']]);
// A static dotfs tree at /st (design/epoch-0/mounts.md, "Static trees"): /a, /big
// (read by Range), and /sub, with its own index.
const { blake3 } = await import(path.join(dir, 'statictree.js'));
const b3 = (s) => Buffer.from(blake3(Buffer.from(s))).toString('hex');
const big = Buffer.alloc(100000, 0).map((_, i) => 97 + (i % 26));
const st = {
  '/.fs/index': `fsindex 1 seq 1\n/ d 755 0 10 1 - -\n/a f 644 6 10 1 b3:${b3('apple\n')} -\n/big f 644 100000 10 1 b3:${b3(big)} -\n/sub d 755 0 10 1 - i\n`,
  '/a': 'apple\n',
  '/big': big,
  '/sub/.fs/index': `fsindex 1 seq 1\n/ d 755 0 10 1 - -\n/b f 644 7 10 1 b3:${b3('banana\n')} -\n`,
  '/sub/b': 'banana\n',
};
const stLog = [];
const server = createServer(async (req, res) => {
  if (req.url === '/stack.h9a') return res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(stack);
  if (req.url.startsWith('/st/') || req.url === '/st') {
    const body = st[req.url.slice(3) || '/'];
    if (body === undefined) return res.writeHead(404).end();
    const b = Buffer.from(body);
    const m = /^bytes=(\d+)-(\d+)$/.exec(req.headers.range ?? '');
    stLog.push(`${m ? 'RANGE' : 'GET'} ${req.url.slice(3)}`);
    if (!m) return res.writeHead(200).end(b);
    const last = Math.min(Number(m[2]), b.length - 1);
    return res.writeHead(206, { 'content-range': `bytes ${m[1]}-${last}/${b.length}` }).end(b.subarray(Number(m[1]), last + 1));
  }
  let p = path.join(dir, decodeURIComponent(new URL(req.url, 'http://x').pathname));
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
let failed = false;
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  const term = page.locator('#term');
  // The terminal's text, without the cursor at its end.
  const text = () => term.evaluate((e) => e.textContent.slice(0, -1));
  // Waits until the terminal's text after `from` matches `re`.
  const expect = async (re, from, ms = 30_000) => {
    const end = Date.now() + ms;
    for (;;) {
      const t = (await text()).slice(from);
      if (re.test(t)) return t;
      if (Date.now() > end) throw new Error(`waiting for ${re}; terminal:\n${await text()}\nerrors: ${errors.join('\n')}`);
      await page.waitForTimeout(100);
    }
  };
  // Drops files, [name, contents] pairs, on the terminal, as a drag from
  // the desktop does.
  const drop = (files) => term.evaluate((t, files) => {
    const dt = new DataTransfer();
    for (const [name, body] of files) dt.items.add(new File([body], name));
    for (const type of ['dragover', 'drop']) t.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true }));
  }, files);
  const step = async (name, f) => {
    const t0 = Date.now();
    await f();
    console.log(`ok: ${name} (${Date.now() - t0} ms)`);
  };
  const test = step;

  // rc on h9's own 386 CPU (h86): the default, and ?backend=v86, the old
  // backend's name, which runs the same.
  for (const backend of ['emu', 'v86']) {
    await page.goto(`${url}?backend=${backend}`);
    const on = (name, f) => step(`${backend}: ${name}`, f);
    await on('rc prompts', () => expect(/% $/, 0, 60_000));
    await term.focus();
    await on('ls /bin | wc -l counts the archive\'s /bin', async () => {
      const at = (await text()).length;
      await page.keyboard.type('ls /bin | wc -l\n');
      const t = await expect(/\d+\n% $/, at);
      const n = Number(t.match(/(\d+)\n% $/)[1]);
      if (n < 40) throw new Error(`only ${n} in /bin`);
    });
    await on('the interrupt key stops cat and rc carries on', async () => {
      let at = (await text()).length;
      await page.keyboard.type('cat\n');
      await page.waitForTimeout(500);
      await page.keyboard.press('Control+c');
      await expect(/% $/, at);
      at = (await text()).length;
      await page.keyboard.type('echo x^y\n');
      await expect(/xy\n% $/, at);
    });
    await on('a pipeline runs while a process spins', async () => {
      const at = (await text()).length;
      await page.keyboard.type('{while(){}} & s=$apid; echo hello | tr h H; echo kill >/proc/$s/note\n');
      await expect(/Hello\n(.|\n)*% $/, at);
    });
    await on('on-screen keyboard input reaches rc', async () => {
      // A phone's keyboard comes up for the focused textarea, and inserts
      // text and deletes without key events.
      await page.evaluate(() => document.activeElement.blur());
      await term.click();
      if (await page.evaluate(() => document.activeElement.id) !== 'kbd') throw new Error('a tap on the terminal does not focus its input');
      const at = (await text()).length;
      await page.keyboard.insertText('echo helo');
      await page.locator('#kbd').evaluate((k) => { k.value = ''; k.dispatchEvent(new InputEvent('input', { inputType: 'deleteContentBackward' })); });
      await page.keyboard.insertText('lo\n');
      await expect(/echo hello\nhello\n% $/, at);
    });
    await on('dropped files land in /usr/glenda, with their paths typed', async () => {
      await term.focus();
      let at = (await text()).length;
      await page.keyboard.type('cat ');
      await drop([['notes.txt', 'dropped\n'], ['run me', '#!/bin/rc\necho ran $0\n']]);
      await expect(/cat \/usr\/glenda\/notes.txt '\/usr\/glenda\/run me' $/, at);
      await page.keyboard.type('\n');
      await expect(/\ndropped\n#!\/bin\/rc\necho ran \$0\n% $/, at);
      at = (await text()).length;
      await page.keyboard.type("'/usr/glenda/run me'\n");
      await expect(/\nran \/usr\/glenda\/run me\n% $/, at);
    });
  }
  if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`);

  // createMachine's mounts (design/epoch-0/mounts.md): two archives stacked on /,
  // and with H9_TEST_WS_ROOT, a ws:// server mounted beside them.
  const wsRoot = process.env.H9_TEST_WS_ROOT;
  await test('createMachine mounts an archive stack and a ws:// URL [mounts]', async () => {
    const r = await page.evaluate(async (ws) => {
      const { createMachine } = await import('./h9-web.js');
      const out = [];
      const terminal = { write: (b) => out.push(new TextDecoder().decode(b)), setRaw() {} };
      const m = await createMachine({
        mounts: [{ archive: 'root.h9a' }, '--archive=stack.h9a:/', ...(ws ? [{ url: ws, dst: '/n/ws' }] : [])],
        binds: ['/lib:/mnt/temp'],
        terminal,
      });
      const code = await m.run(['/bin/rc', '-c', `cat /lib/stacked /mnt/temp/stacked; test -x /bin/rc && echo rc${ws ? '; test -d /n/ws/bin && echo ws' : ''}`]);
      return { code, out: out.join('') };
    }, wsRoot ?? null);
    const want = `stacked\nstacked\nrc\n${wsRoot ? 'ws\n' : ''}`;
    r.out = r.out.replace(/^h9: warning: .*\n/m, '');
    if (r.code !== 0 || r.out !== want) throw new Error(`mounts: ${JSON.stringify(r)}`);
  });

  // design/upper-layers.md: up on a mount the page names, here a layer
  // in memory over /n/l, which the machine makes.
  await test('createMachine takes up: true as the up option [upper-layers]', async () => {
    const r = await page.evaluate(async () => {
      const { createMachine } = await import('./h9-web.js');
      const out = [];
      const terminal = { write: (b) => out.push(new TextDecoder().decode(b)), setRaw() {} };
      const m = await createMachine({ mounts: [{ archive: 'root.h9a' }, { tmp: true, dst: '/n/l', up: true }], terminal });
      const code = await m.run(['/bin/rc', '-c', "echo x >/n/l/f && cat /n/l/f; ns | grep -c 'bind -u'"]);
      return { code, out: out.join('') };
    });
    r.out = r.out.replace(/^h9: warning: .*\n/m, '');
    if (r.code !== 0 || r.out !== 'x\n1\n') throw new Error(`up: ${JSON.stringify(r)}`);
  });

  await test('createMachine mounts a static tree over fetch [mounts]', async () => {
    const r = await page.evaluate(async (st) => {
      const { createMachine } = await import('./h9-web.js');
      const out = [];
      const terminal = { write: (b) => out.push(new TextDecoder().decode(b)), setRaw() {} };
      const m = await createMachine({ mounts: [{ archive: 'root.h9a' }, { url: st, dst: '/n/st' }], terminal });
      const code = await m.run(['/bin/rc', '-c', 'ls /n/st; cat /n/st/a /n/st/sub/b; wc -c </n/st/big']);
      return { code, out: out.join('') };
    }, `${url}st`);
    r.out = r.out.replace(/^h9: warning: .*\n/m, '').replace(/ +(\d+\n)$/, '$1');
    const want = '/n/st/a\n/n/st/big\n/n/st/sub\napple\nbanana\n100000\n';
    if (r.code !== 0 || r.out !== want) throw new Error(`static tree: ${JSON.stringify(r)}`);
    if (!stLog.includes('RANGE /big') || stLog.includes('GET /big')) throw new Error(`static tree requests: ${stLog.join(', ')}`);
  });

  // With linux.h9a, ?linux runs Alpine's arm64 busybox sh, jq and sqlite3
  // on ha64 (design/epoch-0/hcpu.md).
  if (await readFile(path.join(dir, 'linux.h9a')).then(() => true, () => false)) {
    await page.goto(`${url}?linux`);
    await step('busybox sh prompts over linux.h9a', () => expect(/# $/, 0, 60_000));
    await term.focus();
    await step('uname -m says aarch64', async () => {
      const at = (await text()).length;
      await page.keyboard.type('uname -m\n');
      await expect(/aarch64\n.*# $/, at);
    });
    await step('jq and sqlite3 run', async () => {
      const at = (await text()).length;
      await page.keyboard.type(`seq 3 | jq -s add; echo 'select 6*7;' | sqlite3\n`);
      await expect(/6\n42\n.*# $/, at);
    });
    // With nine-arm64.h9a, the page puts the arm64 slim root at /9, and
    // a #!/bin/rc script runs with its rc (src/web/nine-arm64.list).
    if (await readFile(path.join(dir, 'nine-arm64.h9a')).then(() => true, () => false)) {
      await step("9front's rc runs from /9", async () => {
        const at = (await text()).length;
        await page.keyboard.type(`printf '#!/bin/rc\\necho rc on $cputype\\n' >/tmp/r; chmod +x /tmp/r; /tmp/r\n`);
        await expect(/rc on arm64\n.*# $/, at);
      });
    }
    await step('a dropped script lands in /root, and Enter runs it', async () => {
      await term.focus();
      const at = (await text()).length;
      await drop([['hi.sh', '#!/bin/sh\necho hi from $0\n']]);
      await expect(/\/root\/hi.sh $/, at);
      await page.keyboard.type('\n');
      await expect(/\nhi from \/root\/hi.sh\n.*# $/, at);
    });
    await step('dragging over the terminal selects its text, and typing still works', async () => {
      const box = await term.boundingBox();
      await page.mouse.move(box.x + 20, box.y + 15);
      await page.mouse.down();
      await page.mouse.move(box.x + 300, box.y + 60, { steps: 10 });
      await page.mouse.up();
      const sel = await page.evaluate(() => getSelection().toString());
      if (!sel) throw new Error('nothing selected');
      const at = (await text()).length;
      await page.keyboard.type('echo typed\n');
      await expect(/typed\n.*# $/, at);
    });
    if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`);
  }

  // With H9_TEST_WS_ROOT, a ws:// URL of a 9P server serving a 386 root,
  // the page runs over it (design/epoch-0/websocket-9p.md).
  const ws = process.env.H9_TEST_WS_ROOT;
  if (ws) {
    await page.goto(`${url}?root=${encodeURIComponent(ws)}`);
    await step('rc prompts over a ws:// root', () => expect(/% $/, 0, 60_000));
    await term.focus();
    await step('ls /bin | wc -l counts the server\'s /bin', async () => {
      const at = (await text()).length;
      await page.keyboard.type('ls /bin | wc -l\n');
      const t = await expect(/\d+\n% $/, at);
      const n = Number(t.match(/(\d+)\n% $/)[1]);
      if (n < 40) throw new Error(`only ${n} in /bin`);
    });
    // A page's WebSocket sends no headers, so its credentials callback
    // answers with the URL to connect to (design/epoch-0/credential-helpers.md).
    await step("a credentials callback's url replaces the root's", async () => {
      const r = await page.evaluate(async (ws) => {
        const { createMachine } = await import('./h9-web.js');
        const out = [], calls = [];
        const terminal = { write: (b) => out.push(new TextDecoder().decode(b)), setRaw() {} };
        const m = await createMachine({
          mounts: [{ url: 'ws://127.0.0.1:1/stale' }], terminal,
          credentials: async (url, failed) => { calls.push([url, failed]); return { url: ws }; },
        });
        const code = await m.run(['/bin/ls', '/bin/rc']);
        const h = await createMachine({ mounts: [{ url: ws }], terminal, credentials: async () => ['Authorization: Bearer x'] });
        const code2 = await h.run(['/bin/echo']);
        return { code, code2, out: out.join(''), calls };
      }, ws);
      if (r.code !== 0 || !r.out.includes('/bin/rc\n')) throw new Error(`over the callback's url: ${JSON.stringify(r)}`);
      if (r.calls.length !== 1 || r.calls[0][0] !== 'ws://127.0.0.1:1/stale' || r.calls[0][1] !== null) throw new Error(`callback calls: ${JSON.stringify(r.calls)}`);
      if (r.code2 !== 125 || !r.out.includes("can't send handshake headers")) throw new Error(`a header answer: ${JSON.stringify(r)}`);
    });
    if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`);
  }
} catch (e) {
  console.error(`FAIL: ${e.message}`);
  failed = true;
} finally {
  await browser.close();
  server.close();
}
process.exit(failed ? 1 : 0);
