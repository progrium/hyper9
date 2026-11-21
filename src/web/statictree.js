// Static dotfs trees on the browser host (design/mounts.md, "Static
// trees"): src/statictree.zig's server, with the page's fetch. h9-web.js
// puts one behind a WebSocket mount whose URL was http:// or https:// and
// whose server didn't upgrade, so the kernel speaks 9P2000 to it as to a
// 9P server over a WebSocket.
//
// - Walks, stats, and directory reads are answered from URL/.fs/index. A
//   directory flagged `i` has its own URL/DIR/.fs/index, fetched the first
//   time something walks into or lists it.
// - A file up to 64 KiB is fetched whole on its first read and kept; a
//   larger one is read by Range requests. A whole file whose index line has
//   a `b3:` hash is checked against it, and a mismatch fails the read with
//   "content changed". Checked contents are kept by hash for the page's
//   life, so trees that share files share them. Files flagged `p` are
//   fetched when the tree is loaded.
// - Symbolic links are resolved inside the tree.
// - Every write, create, remove, and wstat fails.

const wholeMax = 64 << 10;
const maxLinks = 16;
const enc = new TextEncoder();
const dec = new TextDecoder();

// Checked contents, by hash, for every tree on the page.
const blobs = new Map();

// BLAKE3 (https://github.com/BLAKE3-team/BLAKE3-specs), for `b3:` hashes:
// the plain hash of a whole input, 32 bytes.
const IV = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
const PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];
const CHUNK_START = 1, CHUNK_END = 2, PARENT = 4, ROOT = 8;

function compress(cv, m, counter, len, flags) {
  const s = [...cv, IV[0], IV[1], IV[2], IV[3], counter >>> 0, Math.floor(counter / 0x100000000) >>> 0, len, flags];
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  const g = (a, b, c, d, x, y) => {
    s[a] = (s[a] + s[b] + x) | 0; s[d] = rotr(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) | 0; s[b] = rotr(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b] + y) | 0; s[d] = rotr(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) | 0; s[b] = rotr(s[b] ^ s[c], 7);
  };
  let w = m.slice();
  for (let r = 0; r < 7; r++) {
    g(0, 4, 8, 12, w[0], w[1]); g(1, 5, 9, 13, w[2], w[3]); g(2, 6, 10, 14, w[4], w[5]); g(3, 7, 11, 15, w[6], w[7]);
    g(0, 5, 10, 15, w[8], w[9]); g(1, 6, 11, 12, w[10], w[11]); g(2, 7, 8, 13, w[12], w[13]); g(3, 4, 9, 14, w[14], w[15]);
    w = PERM.map((i) => w[i]);
  }
  for (let i = 0; i < 8; i++) { s[i] = (s[i] ^ s[i + 8]) >>> 0; s[i + 8] = (s[i + 8] ^ cv[i]) >>> 0; }
  return s;
}

function words(b, off, len) {
  const w = new Array(16).fill(0);
  for (let i = 0; i < len; i++) w[i >> 2] |= b[off + i] << ((i & 3) * 8);
  return w;
}

// A chunk's or parent's last compression, not yet made.
const chaining = (o) => compress(o.cv, o.m, o.counter, o.len, o.flags).slice(0, 8);

function chunk(b, off, len, counter) {
  let cv = IV;
  const blocks = Math.max(1, Math.ceil(len / 64));
  for (let j = 0; j < blocks - 1; j++) cv = compress(cv, words(b, off + j * 64, 64), counter, 64, j === 0 ? CHUNK_START : 0).slice(0, 8);
  const last = len - (blocks - 1) * 64;
  return { cv, m: words(b, off + (blocks - 1) * 64, last), counter, len: last, flags: (blocks === 1 ? CHUNK_START : 0) | CHUNK_END };
}

export function blake3(b) {
  const n = Math.max(1, Math.ceil(b.length / 1024));
  const stack = [];
  for (let i = 0; i < n - 1; i++) {
    let cv = chaining(chunk(b, i * 1024, 1024, i));
    for (let t = i + 1; (t & 1) === 0; t >>= 1) cv = chaining({ cv: IV, m: [...stack.pop(), ...cv], counter: 0, len: 64, flags: PARENT });
    stack.push(cv);
  }
  let out = chunk(b, (n - 1) * 1024, b.length - (n - 1) * 1024, n - 1);
  while (stack.length) out = { cv: IV, m: [...stack.pop(), ...chaining(out)], counter: 0, len: 64, flags: PARENT };
  const h = compress(out.cv, out.m, 0, out.len, out.flags | ROOT);
  const r = new Uint8Array(32);
  for (let i = 0; i < 8; i++) for (let k = 0; k < 4; k++) r[i * 4 + k] = (h[i] >>> (k * 8)) & 0xff;
  return r;
}

const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

// %XX escapes, as src/rootindex.zig's unescape.
function unescape(s) {
  if (!s.includes('%')) return s;
  const out = [];
  const b = enc.encode(s);
  for (let i = 0; i < b.length; i++) {
    if (b[i] === 0x25 && i + 2 < b.length + 0) {
      const v = parseInt(String.fromCharCode(b[i + 1], b[i + 2]), 16);
      if (Number.isNaN(v)) throw new Error('bad escape');
      out.push(v);
      i += 2;
    } else out.push(b[i]);
  }
  return dec.decode(new Uint8Array(out));
}

class Fail extends Error {}

/**
 * A static tree at `base` (http:// or https://, no trailing /), with
 * `index` its .fs/index text. `fetchFn` is the page's fetch.
 */
export class StaticTree {
  constructor(base, index, fetchFn = (...a) => fetch(...a)) {
    this.base = base.replace(/\/+$/, '');
    this.fetch = fetchFn;
    this.nodes = [{ name: '/', parent: 0, kind: 'd', perm: 0o555, length: 0, mtime: 0, version: 0, hash: null, nested: false, prefetch: false, target: '', uid: 'none', gid: 'none', kids: [] }];
    this.whole = new Map();
    this.load(0, index);
  }

  /** Fetches the files flagged p. */
  async prefetch() {
    for (let i = 0; i < this.nodes.length; i++) if (this.nodes[i].prefetch && this.nodes[i].kind === 'f') await this.wholeOf(i).catch(() => {});
  }

  load(at, text) {
    const lines = text.split('\n');
    const h = (lines[0] ?? '').split(' ');
    if (h[0] !== 'fsindex' || h[1] !== '1') throw new Fail('not an fsindex 1');
    const byPath = new Map([['/', at]]);
    lines.forEach((line, li) => {
      if (li === 0 || line === '') return;
      const bad = (m) => { throw new Fail(`index line ${li + 1}: ${m}`); };
      const f = line.split(' ');
      if (f.length < 8) bad('too few fields');
      const path = unescape(f[0]);
      if (!path.startsWith('/')) bad('bad path');
      const kind = f[1];
      if (!['d', 'f', 'l'].includes(kind)) bad('bad type');
      const perm = parseInt(f[2], 8), length = Number(f[3]), mtime = Number(f[4]), version = Number(f[5]);
      if ([perm, length, mtime, version].some((x) => Number.isNaN(x))) bad('bad number');
      const hash = f[6].startsWith('b3:') ? f[6].slice(3) : null;
      if (hash !== null && !/^[0-9a-f]{64}$/.test(hash)) bad('bad hash');
      const flags = f[7] === '-' ? '' : f[7];
      let rest = f.slice(8);
      let target = '';
      if (kind === 'l') {
        if (!rest.length) bad('symlink without a target');
        target = unescape(rest[0]);
        rest = rest.slice(1);
      }
      let uid = 'none', gid = 'none';
      for (const kv of rest) {
        if (kv.startsWith('9p.uid=')) uid = unescape(kv.slice(7));
        if (kv.startsWith('9p.gid=')) gid = unescape(kv.slice(7));
      }
      if (path === '/') {
        if (kind !== 'd') bad("the top isn't a directory");
        Object.assign(this.nodes[at], { perm, mtime, version, uid, gid });
        return;
      }
      const slash = path.lastIndexOf('/');
      const parent = byPath.get(slash === 0 ? '/' : path.slice(0, slash));
      if (parent === undefined) bad('no parent before it');
      if (this.nodes[parent].kind !== 'd') bad("parent isn't a directory");
      const id = this.nodes.length;
      this.nodes.push({ name: path.slice(slash + 1), parent, kind, perm, length: kind === 'l' ? enc.encode(target).length : length, mtime, version, hash, nested: kind === 'd' && flags.includes('i'), prefetch: flags.includes('p'), target, uid, gid, kids: [] });
      this.nodes[parent].kids.push(id);
      byPath.set(path, id);
    });
  }

  pathOf(i) {
    const names = [];
    for (let at = i; at !== 0; at = this.nodes[at].parent) names.unshift(this.nodes[at].name);
    return '/' + names.join('/');
  }

  urlOf(i, suffix = '') {
    const p = i === 0 ? '' : this.pathOf(i).split('/').map((n) => encodeURIComponent(n)).join('/');
    return this.base + p + suffix;
  }

  async get(url, range) {
    let r;
    try {
      r = await this.fetch(url, range ? { headers: { Range: `bytes=${range[0]}-${range[1]}` } } : {});
    } catch (e) {
      throw new Fail(`${url}: ${e?.message ?? 'fetch failed'}`);
    }
    return r;
  }

  async expand(d) {
    const n = this.nodes[d];
    if (!n.nested) return;
    const url = this.urlOf(d, '/.fs/index');
    const r = await this.get(url);
    if (r.status !== 200) throw new Fail(`${url}: ${r.status} ${r.statusText}`);
    const text = await r.text();
    n.nested = false;
    this.load(d, text);
  }

  check(n, body) {
    if (n.hash === null) return;
    if (hex(blake3(body)) !== n.hash) throw new Fail('content changed');
    blobs.set(n.hash, body);
  }

  async wholeOf(i) {
    if (this.whole.has(i)) return this.whole.get(i);
    const n = this.nodes[i];
    if (n.hash !== null && blobs.has(n.hash)) {
      this.whole.set(i, blobs.get(n.hash));
      return blobs.get(n.hash);
    }
    const url = this.urlOf(i);
    const r = await this.get(url);
    if (r.status !== 200) throw new Fail(`${url}: ${r.status} ${r.statusText}`);
    const body = new Uint8Array(await r.arrayBuffer());
    this.check(n, body);
    this.whole.set(i, body);
    return body;
  }

  async read(i, off, count) {
    const n = this.nodes[i];
    if (off >= n.length) return new Uint8Array(0);
    const want = Math.min(count, n.length - off);
    if (n.length <= wholeMax || this.whole.has(i) || (n.hash !== null && blobs.has(n.hash))) {
      return (await this.wholeOf(i)).subarray(off, off + want);
    }
    const url = this.urlOf(i);
    const r = await this.get(url, [off, off + want - 1]);
    if (r.status === 206) return new Uint8Array(await r.arrayBuffer()).subarray(0, want);
    if (r.status === 200) {
      // The server ignored the Range: it's the whole file.
      const body = new Uint8Array(await r.arrayBuffer());
      this.check(n, body);
      this.whole.set(i, body);
      return body.subarray(off, off + want);
    }
    throw new Fail(`${url}: ${r.status} ${r.statusText}`);
  }

  async lookup(d, name) {
    if (name === '..') return this.nodes[d].parent;
    if (name === '.') return d;
    await this.expand(d);
    return this.nodes[d].kids.find((c) => this.nodes[c].name === name) ?? null;
  }

  // What node i is once its links are followed, inside the tree; null for
  // a link that leads nowhere.
  async resolve(i, depth = 0) {
    const n = this.nodes[i];
    if (n.kind !== 'l') return i;
    if (depth >= maxLinks) return null;
    let at = n.target.startsWith('/') ? 0 : n.parent;
    for (const name of n.target.split('/').filter((x) => x)) {
      at = await this.resolve(at, depth + 1);
      if (at === null || this.nodes[at].kind !== 'd') return null;
      at = await this.lookup(at, name);
      if (at === null) return null;
    }
    return this.resolve(at, depth + 1);
  }
}

// 9P2000 messages.
const T = { version: 100, auth: 102, attach: 104, flush: 108, walk: 110, open: 112, create: 114, read: 116, write: 118, clunk: 120, remove: 122, stat: 124, wstat: 126 };
const Rerror = 107;
const QTDIR = 0x80, DMDIR = 0x80000000;

class Out {
  constructor() { this.b = []; }
  u8(v) { this.b.push(v & 0xff); return this; }
  u16(v) { return this.u8(v).u8(v >>> 8); }
  u32(v) { return this.u16(v & 0xffff).u16(v >>> 16); }
  u64(v) { return this.u32(v % 0x100000000).u32(Math.floor(v / 0x100000000)); }
  str(s) { const e = enc.encode(s); this.u16(e.length); for (const x of e) this.b.push(x); return this; }
  bytes(e) { for (const x of e) this.b.push(x); return this; }
  qid(q) { return this.u8(q.type).u32(q.vers).u64(q.path); }
  msg(type, tag) {
    const n = this.b.length + 7;
    const r = new Uint8Array(n);
    const v = new DataView(r.buffer);
    v.setUint32(0, n, true);
    r[4] = type;
    v.setUint16(5, tag, true);
    r.set(this.b, 7);
    return r;
  }
}

/**
 * One connection's 9P2000 session over a tree: `handle` takes the bytes
 * the kernel sends and gives the replies, in order.
 */
export class Session {
  constructor(tree) {
    this.t = tree;
    this.msize = 8192;
    this.fids = new Map();
    this.buf = new Uint8Array(0);
    this.chain = Promise.resolve();
  }

  qid(i) {
    const n = this.t.nodes[i];
    return { type: n.kind === 'd' ? QTDIR : 0, vers: n.version >>> 0, path: i + 1 };
  }

  stat(i, name) {
    const n = this.t.nodes[i];
    const s = new Out().u16(0).u16(0).u32(0).qid(this.qid(i)).u32((n.perm & 0o777) | (n.kind === 'd' ? DMDIR : 0) >>> 0)
      .u32(n.mtime).u32(n.mtime).u64(n.kind === 'd' || n.kind === 'l' ? 0 : n.length).str(name).str(n.uid).str(n.gid).str('');
    const b = Uint8Array.from(s.b);
    new DataView(b.buffer).setUint16(0, b.length - 2, true);
    return b;
  }

  /** Queues `bytes`, calling `reply` with each answer in order. */
  feed(bytes, reply) {
    const nb = new Uint8Array(this.buf.length + bytes.length);
    nb.set(this.buf);
    nb.set(bytes, this.buf.length);
    this.buf = nb;
    while (this.buf.length >= 4) {
      const size = new DataView(this.buf.buffer, this.buf.byteOffset).getUint32(0, true);
      if (size < 7 || this.buf.length < size) break;
      const m = this.buf.slice(0, size);
      this.buf = this.buf.slice(size);
      this.chain = this.chain.then(() => this.answer(m)).then(reply, () => {});
    }
  }

  async answer(m) {
    const v = new DataView(m.buffer);
    const type = m[4], tag = v.getUint16(5, true);
    let p = 7;
    const u16 = () => { const x = v.getUint16(p, true); p += 2; return x; };
    const u32 = () => { const x = v.getUint32(p, true); p += 4; return x; };
    const u64 = () => { const x = u32() + u32() * 0x100000000; return x; };
    const str = () => { const n = u16(); const s = dec.decode(m.subarray(p, p + n)); p += n; return s; };
    const err = (e) => new Out().str(e).msg(Rerror, tag);
    const t = this.t;
    try {
      switch (type) {
        case T.version: {
          this.msize = Math.min(u32(), 64 << 10);
          const ver = str().startsWith('9P2000') ? '9P2000' : 'unknown';
          this.fids.clear();
          return new Out().u32(this.msize).str(ver).msg(type + 1, tag);
        }
        case T.auth: return err('no authentication required');
        case T.attach: {
          const fid = u32();
          if (this.fids.has(fid)) return err('fid in use');
          this.fids.set(fid, { node: 0, open: false, cursor: 0 });
          return new Out().qid(this.qid(0)).msg(type + 1, tag);
        }
        case T.flush: return new Out().msg(type + 1, tag);
        case T.walk: {
          const fid = u32(), newfid = u32(), n = u16();
          const names = Array.from({ length: n }, str);
          const from = this.fids.get(fid);
          if (!from) return err('unknown fid');
          if (from.open) return err('fid is open');
          if (newfid !== fid && this.fids.has(newfid)) return err('fid in use');
          const qids = [];
          let at = from.node;
          for (const name of names) {
            const d = await t.resolve(at);
            if (d === null || t.nodes[d].kind !== 'd') break;
            const c = await t.lookup(d, name);
            if (c === null) break;
            const real = await t.resolve(c);
            if (real === null) break;
            at = c;
            qids.push(this.qid(real));
          }
          if (qids.length === 0 && n > 0) return err('file does not exist');
          if (qids.length === n) this.fids.set(newfid, { node: (await t.resolve(at)) ?? at, open: false, cursor: 0 });
          const o = new Out().u16(qids.length);
          for (const q of qids) o.qid(q);
          return o.msg(type + 1, tag);
        }
        case T.open: {
          const f = this.fids.get(u32());
          if (!f) return err('unknown fid');
          const mode = m[p];
          if ((mode & 3) === 1 || (mode & 3) === 2 || (mode & 0x50) !== 0) return err('read-only file system');
          f.open = true;
          f.cursor = 0;
          return new Out().qid(this.qid(f.node)).u32(0).msg(type + 1, tag);
        }
        case T.create: case T.write: case T.wstat: return err('read-only file system');
        case T.remove: this.fids.delete(u32()); return err('read-only file system');
        case T.clunk: this.fids.delete(u32()); return new Out().msg(type + 1, tag);
        case T.stat: {
          const f = this.fids.get(u32());
          if (!f) return err('unknown fid');
          const s = this.stat(f.node, t.nodes[f.node].name);
          return new Out().u16(s.length).bytes(s).msg(type + 1, tag);
        }
        case T.read: {
          const f = this.fids.get(u32());
          const off = u64();
          const count = Math.min(u32(), this.msize - 24);
          if (!f) return err('unknown fid');
          if (!f.open) return err('fid not open');
          let data;
          if (t.nodes[f.node].kind === 'd') {
            await t.expand(f.node);
            if (off === 0) f.cursor = 0;
            const parts = [];
            let k = 0;
            const kids = t.nodes[f.node].kids;
            while (f.cursor < kids.length) {
              const c = kids[f.cursor];
              const real = (await t.resolve(c)) ?? c;
              const s = this.stat(real, t.nodes[c].name);
              if (k + s.length > count) break;
              parts.push(s);
              k += s.length;
              f.cursor++;
            }
            data = new Uint8Array(k);
            let at = 0;
            for (const s of parts) { data.set(s, at); at += s.length; }
          } else data = await t.read(f.node, off, count);
          return new Out().u32(data.length).bytes(data).msg(type + 1, tag);
        }
        default: return err('bad message');
      }
    } catch (e) {
      return err(e instanceof Fail ? e.message : (e?.message ?? 'error'));
    }
  }
}

/**
 * Fetches `url`/.fs/index: a StaticTree on a 200, or an Error naming what
 * the server said.
 */
export async function openStatic(url, fetchFn = (...a) => fetch(...a)) {
  const base = url.replace(/\/+$/, '');
  let r;
  try {
    r = await fetchFn(`${base}/.fs/index`);
  } catch (e) {
    return new Error(`/.fs/index: ${e?.message ?? 'fetch failed'}`);
  }
  if (r.status !== 200) return new Error(`/.fs/index: ${r.status} ${r.statusText}`.trim());
  try {
    const t = new StaticTree(base, await r.text(), fetchFn);
    await t.prefetch();
    return t;
  } catch (e) {
    return new Error(`/.fs/index: ${e.message}`);
  }
}
