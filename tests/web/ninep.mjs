// A small 9P2000 client and server over MessagePorts, one 9P message per
// message (design/epoch-0/port-streams.md), for the namespace kernel's
// cases (design/epoch-0/namespace-kernel.md, The JS API).

export const NOFID = 0xffffffff;
export const OREAD = 0, OWRITE = 1, ORDWR = 2, OTRUNC = 0x10;
export const DMDIR = 0x80000000;
export const QTDIR = 0x80;

const T = { version: 100, auth: 102, attach: 104, error: 106, flush: 108, walk: 110, open: 112, create: 114, read: 116, write: 118, clunk: 120, remove: 122, stat: 124, wstat: 126 };
const enc = new TextEncoder();
const dec = new TextDecoder();

// Message building and parsing, little-endian.
class W {
  constructor() { this.b = []; }
  u8(v) { this.b.push(v & 0xff); return this; }
  u16(v) { return this.u8(v).u8(v >>> 8); }
  u32(v) { return this.u16(v & 0xffff).u16(v >>> 16); }
  u64(v) { const n = BigInt(v); return this.u32(Number(n & 0xffffffffn)).u32(Number(n >> 32n)); }
  str(s) { const b = enc.encode(s); this.u16(b.length); for (const x of b) this.b.push(x); return this; }
  bytes(a) { for (const x of a) this.b.push(x); return this; }
  qid(q) { return this.u8(q.type).u32(q.vers ?? 0).u64(q.path); }
  msg(type, tag) {
    const out = new Uint8Array(7 + this.b.length);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, out.length, true);
    out[4] = type;
    dv.setUint16(5, tag, true);
    out.set(this.b, 7);
    return out;
  }
}

class R {
  constructor(b, off = 0) { this.b = b; this.dv = new DataView(b.buffer, b.byteOffset, b.byteLength); this.p = off; }
  u8() { return this.b[this.p++]; }
  u16() { const v = this.dv.getUint16(this.p, true); this.p += 2; return v; }
  u32() { const v = this.dv.getUint32(this.p, true); this.p += 4; return v; }
  u64() { const v = this.dv.getBigUint64(this.p, true); this.p += 8; return Number(v); }
  str() { const n = this.u16(); const s = dec.decode(this.b.subarray(this.p, this.p + n)); this.p += n; return s; }
  bytes(n) { const s = this.b.subarray(this.p, this.p + n); this.p += n; return s; }
  qid() { return { type: this.u8(), vers: this.u32(), path: this.u64() }; }
}

const asBytes = (d) => (d instanceof ArrayBuffer ? new Uint8Array(d) : new Uint8Array(d.buffer, d.byteOffset, d.byteLength));
const sendMsg = (port, m) => port.postMessage(m.buffer, [m.buffer]);

function statBytes(d) {
  const w = new W().u16(0).u32(0).qid(d.qid).u32(d.mode).u32(0).u32(0).u64(d.length ?? 0)
    .str(d.name).str('none').str('none').str('none');
  const body = new Uint8Array(w.b);
  const out = new Uint8Array(2 + body.length);
  new DataView(out.buffer).setUint16(0, body.length, true);
  out.set(body, 2);
  return out;
}

/** Parses a directory's read, stat entries back to back, to names. */
export function dirNames(b) {
  const names = [];
  const r = new R(b);
  while (r.p + 2 <= b.length) {
    const size = r.u16();
    const end = r.p + size;
    r.p += 2 + 4 + 13 + 4 + 4 + 4 + 8;
    names.push(r.str());
    r.p = end;
  }
  return names.sort();
}

/** A 9P2000 client on `port`. Errors reject with the server's message. */
export class Client {
  constructor(port, { msize = 8192 + 24 } = {}) {
    this.port = port;
    this.msize = msize;
    this.tags = new Map();
    this.nextTag = 1;
    this.nextFid = 1;
    this.closed = null;
    port.onmessage = ({ data }) => {
      if (data === null) return this.hangup('hung up');
      const b = asBytes(data);
      const r = new R(b, 4);
      const type = r.u8();
      const tag = r.u16();
      const w = this.tags.get(tag);
      if (!w) return;
      this.tags.delete(tag);
      if (type === T.error + 1) w.reject(new Error(r.str()));
      else if (type !== w.type + 1) w.reject(new Error(`9P: R${type} for T${w.type}`));
      else w.resolve(r);
    };
  }

  hangup(why) {
    this.closed = why;
    for (const w of this.tags.values()) w.reject(new Error(why));
    this.tags.clear();
  }

  rpc(type, build, tag) {
    if (this.closed) return Promise.reject(new Error(this.closed));
    const t = tag ?? this.nextTag++;
    if (this.nextTag > 0xfffe) this.nextTag = 1;
    const w = new W();
    build?.(w);
    return new Promise((resolve, reject) => {
      this.tags.set(t, { type, resolve, reject });
      sendMsg(this.port, w.msg(type, t));
    });
  }

  /** Tversion, then Tattach to `aname`: resolves to the root's fid. */
  async connect(aname = '', uname = 'test') {
    const r = await this.rpc(T.version, (w) => w.u32(this.msize).str('9P2000'), 0xffff);
    this.msize = Math.min(this.msize, r.u32());
    const v = r.str();
    if (v !== '9P2000') throw new Error(`9P: version ${v}`);
    const fid = this.nextFid++;
    await this.rpc(T.attach, (w) => w.u32(fid).u32(NOFID).str(uname).str(aname));
    this.root = fid;
    return fid;
  }

  async walk(fid, path) {
    const names = path.split('/').filter((s) => s);
    const nfid = this.nextFid++;
    const r = await this.rpc(T.walk, (w) => { w.u32(fid).u32(nfid).u16(names.length); for (const n of names) w.str(n); });
    if (r.u16() !== names.length) throw new Error(`${path}: file does not exist`);
    return nfid;
  }
  async open(fid, mode) { const r = await this.rpc(T.open, (w) => w.u32(fid).u8(mode)); return r.qid(); }
  async create(fid, name, perm, mode) { await this.rpc(T.create, (w) => w.u32(fid).str(name).u32(perm).u8(mode)); }
  async read(fid, off, n = this.msize - 24) {
    const r = await this.rpc(T.read, (w) => w.u32(fid).u64(off).u32(Math.min(n, this.msize - 24)));
    return r.bytes(r.u32()).slice();
  }
  async readAll(fid) {
    const parts = [];
    let off = 0;
    for (;;) {
      const b = await this.read(fid, off);
      if (b.length === 0) break;
      parts.push(b);
      off += b.length;
    }
    const out = new Uint8Array(off);
    let p = 0;
    for (const b of parts) { out.set(b, p); p += b.length; }
    return out;
  }
  async write(fid, off, data) {
    const b = typeof data === 'string' ? enc.encode(data) : data;
    const r = await this.rpc(T.write, (w) => w.u32(fid).u64(off).u32(b.length).bytes(b));
    return r.u32();
  }
  async clunk(fid) { await this.rpc(T.clunk, (w) => w.u32(fid)); }

  /** Reads `path` from the root, as text. */
  async cat(path) {
    const f = await this.walk(this.root, path);
    try {
      await this.open(f, OREAD);
      return dec.decode(await this.readAll(f));
    } finally { await this.clunk(f); }
  }
  /** Writes `data` to `path` from the root, in one Twrite. */
  async put(path, data) {
    const f = await this.walk(this.root, path);
    try {
      await this.open(f, OWRITE);
      await this.write(f, 0, data);
    } finally { await this.clunk(f); }
  }
  /** Makes `path`: a directory with `dir`, else a file holding `data`. */
  async make(path, { dir = false, data = '' } = {}) {
    const i = path.lastIndexOf('/');
    const f = await this.walk(this.root, path.slice(0, Math.max(i, 0)));
    try {
      await this.create(f, path.slice(i + 1), dir ? (DMDIR | 0o775) >>> 0 : 0o664, dir ? OREAD : ORDWR);
      if (!dir && data.length) await this.write(f, 0, data);
    } finally { await this.clunk(f); }
  }
  /** The sorted names in directory `path`. */
  async ls(path) {
    const f = await this.walk(this.root, path);
    try {
      await this.open(f, OREAD);
      return dirNames(await this.readAll(f));
    } finally { await this.clunk(f); }
  }
  /** Opens a ctl-like file at `path` for reading and writing; its fid. */
  async openRW(path) {
    const f = await this.walk(this.root, path);
    await this.open(f, ORDWR);
    return f;
  }
  close() {
    try { this.port.postMessage(null); } catch {}
    this.port.close();
    this.hangup('closed');
  }
}

/**
 * Serves a read-only tree on `port`: `files` maps paths ('a/b') to text.
 * Directories are the paths' prefixes.
 */
export function serveTree(port, files) {
  const root = { dir: true, mode: 0o40555, kids: new Map(), ino: 1, nextIno: 2 };
  for (const [p, text] of Object.entries(files)) {
    const parts = p.split('/').filter((x) => x);
    let d = root;
    for (const name of parts.slice(0, -1)) {
      if (!d.kids.has(name)) d.kids.set(name, { dir: true, mode: 0o40555, kids: new Map(), ino: root.nextIno++ });
      d = d.kids.get(name);
    }
    d.kids.set(parts[parts.length - 1], { dir: false, mode: 0o100444, data: enc.encode(text), ino: root.nextIno++ });
  }
  serveNodes(port, root);
}

/**
 * Serves a read-only tree of nodes on `port`, in src/web/wasi-mem.js's
 * shape: { dir, mode, kids: Map of name to node, data, ino }.
 */
export function serveNodes(port, root) {
  const qid = (n) => ({ type: n.dir ? QTDIR : 0, vers: 0, path: n.ino ?? 0 });
  const dirOf = (n, name) => ({ qid: qid(n), mode: n.dir ? (DMDIR | (n.mode & 0o777)) >>> 0 : n.mode & 0o777, length: n.dir ? 0 : n.data.length, name });
  const fids = new Map();
  let msize = 8192 + 24;
  const reply = (type, tag, build) => { const w = new W(); build?.(w); sendMsg(port, w.msg(type + 1, tag)); };
  const fail = (tag, msg) => { const w = new W().str(msg); sendMsg(port, w.msg(T.error + 1, tag)); };
  port.onmessage = ({ data }) => {
    if (data === null) { port.close(); return; }
    const r = new R(asBytes(data), 4);
    const type = r.u8();
    const tag = r.u16();
    switch (type) {
      case T.version: msize = Math.min(msize, r.u32()); fids.clear(); return reply(type, tag, (w) => w.u32(msize).str('9P2000'));
      case T.auth: return fail(tag, 'no authentication required');
      case T.attach: { const fid = r.u32(); fids.set(fid, { path: [[root, '/']] }); return reply(type, tag, (w) => w.qid(qid(root))); }
      case T.flush: return reply(type, tag);
      case T.walk: {
        const f = fids.get(r.u32()); const nfid = r.u32(); const n = r.u16();
        if (!f) return fail(tag, 'unknown fid');
        const path = [...f.path]; const qs = [];
        for (let i = 0; i < n; i++) {
          const name = r.str();
          const [cur] = path[path.length - 1];
          if (!cur.dir) break;
          if (name === '..') { if (path.length > 1) path.pop(); qs.push(qid(path[path.length - 1][0])); continue; }
          const k = cur.kids.get(name);
          if (!k) break;
          path.push([k, name]); qs.push(qid(k));
        }
        if (n > 0 && qs.length === 0) return fail(tag, 'file does not exist');
        if (qs.length === n) fids.set(nfid, { path });
        return reply(type, tag, (w) => { w.u16(qs.length); for (const q of qs) w.qid(q); });
      }
      case T.open: {
        const f = fids.get(r.u32()); const mode = r.u8();
        if (!f) return fail(tag, 'unknown fid');
        if ((mode & 3) !== OREAD && (mode & 3) !== 3) return fail(tag, 'permission denied');
        const [n] = f.path[f.path.length - 1];
        if (n.dir) f.dir = [...n.kids].map(([name, k]) => statBytes(dirOf(k, name)));
        return reply(type, tag, (w) => w.qid(qid(n)).u32(0));
      }
      case T.read: {
        const f = fids.get(r.u32()); const off = r.u64(); const cnt = Math.min(r.u32(), msize - 24);
        if (!f) return fail(tag, 'unknown fid');
        let out;
        if (f.dir) {
          // Whole entries from offset off, as many as fit.
          let p = 0; const parts = []; let len = 0;
          for (const e of f.dir) {
            if (p >= off && len + e.length <= cnt) { parts.push(e); len += e.length; }
            p += e.length;
          }
          out = new Uint8Array(len); let q = 0; for (const e of parts) { out.set(e, q); q += e.length; }
        } else out = f.path[f.path.length - 1][0].data.subarray(off, off + cnt);
        return reply(type, tag, (w) => w.u32(out.length).bytes(out));
      }
      case T.stat: {
        const f = fids.get(r.u32());
        if (!f) return fail(tag, 'unknown fid');
        const [n, name] = f.path[f.path.length - 1];
        const s = statBytes(dirOf(n, name));
        return reply(type, tag, (w) => w.u16(s.length).bytes(s));
      }
      case T.clunk: fids.delete(r.u32()); return reply(type, tag);
      default: return fail(tag, 'permission denied');
    }
  };
}
