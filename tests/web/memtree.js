// A writable 9P2000 tree in memory, which a page serves a machine on a
// MessagePort: the page's own server for the [upper-layers] case, which
// keeps an up layer there (design/upper-layers.md, "The library and the
// web host"). It's the least a layer needs: walks, creates, reads and
// writes, removes, and wstat of mode, times, length, and name.

const enc = new TextEncoder(), dec = new TextDecoder();
const T = { version: 100, auth: 102, attach: 104, flush: 108, walk: 110, open: 112, create: 114, read: 116, write: 118, clunk: 120, remove: 122, stat: 124, wstat: 126 };
const Rerror = 107;
const QTDIR = 0x80, DMDIR = 0x80000000;
const OTRUNC = 0x10, ORCLOSE = 0x40;
const NOINT = 0xffffffff;

class Fail extends Error {}

class Out {
  constructor() { this.b = []; }
  u8(v) { this.b.push(v & 0xff); return this; }
  u16(v) { return this.u8(v).u8(v >>> 8); }
  u32(v) { return this.u16(v & 0xffff).u16(v >>> 16); }
  u64(v) { return this.u32(v % 0x100000000).u32(Math.floor(v / 0x100000000)); }
  str(s) { const e = enc.encode(s); this.u16(e.length); for (const x of e) this.b.push(x); return this; }
  bytes(e) { for (const x of e) this.b.push(x); return this; }
  qid(n) { return this.u8(n.kids ? QTDIR : 0).u32(n.vers).u64(n.path); }
  msg(type, tag) {
    const r = new Uint8Array(this.b.length + 7);
    const v = new DataView(r.buffer);
    v.setUint32(0, r.length, true);
    r[4] = type;
    v.setUint16(5, tag, true);
    r.set(this.b, 7);
    return r;
  }
}

export class MemTree {
  constructor() {
    this.next = 1;
    this.root = this.make('', true, 0o775, 'none');
    this.root.parent = this.root;
  }

  make(name, dir, perm, uid) {
    return { name, perm, uid, kids: dir ? new Map() : null, data: new Uint8Array(0), path: this.next++, vers: 0, mtime: Math.floor(Date.now() / 1000), parent: null };
  }

  /**
   * Every name in the tree, depth first and sorted, as `path` for a
   * directory (with a trailing `/`) and `path=contents` for a file.
   */
  list() {
    const out = [];
    const walk = (n, pre) => {
      for (const k of [...n.kids.keys()].sort()) {
        const c = n.kids.get(k);
        if (c.kids) { out.push(`${pre}${k}/`); walk(c, `${pre}${k}/`); }
        else out.push(`${pre}${k}=${dec.decode(c.data)}`);
      }
    };
    walk(this.root, '');
    return out;
  }

  /** Serves the tree on `port`, one 9P2000 session, until it hangs up. */
  serve(port) {
    const s = new Session(this);
    let buf = new Uint8Array(0);
    port.onmessage = ({ data }) => {
      if (data === null) return port.close();
      const b = new Uint8Array(data);
      const nb = new Uint8Array(buf.length + b.length);
      nb.set(buf);
      nb.set(b, buf.length);
      buf = nb;
      while (buf.length >= 4) {
        const size = new DataView(buf.buffer, buf.byteOffset).getUint32(0, true);
        if (size < 7 || buf.length < size) break;
        const r = s.answer(buf.slice(0, size));
        buf = buf.slice(size);
        port.postMessage(r.buffer, [r.buffer]);
      }
    };
  }
}

class Session {
  constructor(tree) {
    this.t = tree;
    this.msize = 8192;
    this.fids = new Map();
  }

  stat(n) {
    const s = new Out().u16(0).u16(0).u32(0).qid(n).u32(((n.perm & 0o777) | (n.kids ? DMDIR : 0)) >>> 0)
      .u32(n.mtime).u32(n.mtime).u64(n.kids ? 0 : n.data.length).str(n === this.t.root ? '/' : n.name).str(n.uid).str(n.uid).str(n.uid);
    const b = Uint8Array.from(s.b);
    new DataView(b.buffer).setUint16(0, b.length - 2, true);
    return b;
  }

  touch(n) {
    n.vers = (n.vers + 1) >>> 0;
    n.mtime = Math.floor(Date.now() / 1000);
  }

  unlink(n) {
    if (n === this.t.root) throw new Fail('permission denied');
    if (n.kids && n.kids.size > 0) throw new Fail('directory not empty');
    n.parent.kids.delete(n.name);
    this.touch(n.parent);
  }

  answer(m) {
    const v = new DataView(m.buffer, m.byteOffset);
    const type = m[4], tag = v.getUint16(5, true);
    let p = 7;
    const u8 = () => m[p++];
    const u16 = () => { const x = v.getUint16(p, true); p += 2; return x; };
    const u32 = () => { const x = v.getUint32(p, true); p += 4; return x; };
    const u64 = () => u32() + u32() * 0x100000000;
    const str = () => { const n = u16(); const s = dec.decode(m.subarray(p, p + n)); p += n; return s; };
    const fid = () => {
      const f = this.fids.get(u32());
      if (!f) throw new Fail('unknown fid');
      return f;
    };
    const ok = (o = new Out()) => o.msg(type + 1, tag);
    try {
      switch (type) {
        case T.version: {
          this.msize = Math.min(u32(), 64 << 10);
          this.fids.clear();
          return ok(new Out().u32(this.msize).str(str().startsWith('9P2000') ? '9P2000' : 'unknown'));
        }
        case T.auth: throw new Fail('no authentication required');
        case T.attach: {
          const id = u32();
          u32();
          const uname = str();
          if (this.fids.has(id)) throw new Fail('fid in use');
          this.fids.set(id, { n: this.t.root, uid: uname || 'none' });
          return ok(new Out().qid(this.t.root));
        }
        case T.flush: return ok();
        case T.walk: {
          const from = fid();
          const id = u32(), nw = u16();
          const names = Array.from({ length: nw }, str);
          if (from.open) throw new Fail('fid is open');
          if (this.fids.get(id) && this.fids.get(id) !== from) throw new Fail('fid in use');
          const qids = new Out();
          let at = from.n, k = 0;
          for (const name of names) {
            if (!at.kids) break;
            const c = name === '..' ? at.parent : at.kids.get(name);
            if (!c) break;
            at = c;
            qids.qid(at);
            k++;
          }
          if (k === 0 && nw > 0) throw new Fail('file does not exist');
          if (k === nw) this.fids.set(id, { n: at, uid: from.uid });
          return ok(new Out().u16(k).bytes(qids.b));
        }
        case T.open: {
          const f = fid();
          const mode = u8();
          if (f.n.kids && ((mode & 3) !== 0 || mode & OTRUNC)) throw new Fail('is a directory');
          if (mode & OTRUNC) { f.n.data = new Uint8Array(0); this.touch(f.n); }
          Object.assign(f, { open: true, rclose: !!(mode & ORCLOSE), list: null });
          return ok(new Out().qid(f.n).u32(0));
        }
        case T.create: {
          const f = fid();
          const name = str(), perm = u32(), mode = u8();
          if (!f.n.kids) throw new Fail('not a directory');
          if (f.open) throw new Fail('fid is open');
          if (name === '.' || name === '..' || name.includes('/')) throw new Fail('bad file name');
          if (f.n.kids.has(name)) throw new Fail('file exists');
          const n = this.t.make(name, !!(perm & DMDIR), perm & 0o777, f.uid);
          n.parent = f.n;
          f.n.kids.set(name, n);
          this.touch(f.n);
          Object.assign(f, { n, open: true, rclose: !!(mode & ORCLOSE), list: null });
          return ok(new Out().qid(n).u32(0));
        }
        case T.read: {
          const f = fid();
          const off = u64(), count = Math.min(u32(), this.msize - 24);
          if (!f.open) throw new Fail('fid not open');
          if (!f.n.kids) return ok(new Out().u32(Math.max(0, Math.min(count, f.n.data.length - off))).bytes(f.n.data.subarray(off, off + count)));
          if (off === 0 || !f.list) f.list = { kids: [...f.n.kids.values()], at: 0 };
          const o = new Out();
          while (f.list.at < f.list.kids.length) {
            const s = this.stat(f.list.kids[f.list.at]);
            if (o.b.length + s.length > count) break;
            o.bytes(s);
            f.list.at++;
          }
          return ok(new Out().u32(o.b.length).bytes(o.b));
        }
        case T.write: {
          const f = fid();
          const off = u64(), count = u32();
          if (!f.open || f.n.kids) throw new Fail('permission denied');
          const d = m.subarray(p, p + count);
          if (off + d.length > f.n.data.length) {
            const nd = new Uint8Array(off + d.length);
            nd.set(f.n.data);
            f.n.data = nd;
          }
          f.n.data.set(d, off);
          this.touch(f.n);
          return ok(new Out().u32(d.length));
        }
        case T.clunk: {
          const id = u32();
          const f = this.fids.get(id);
          this.fids.delete(id);
          if (f?.rclose) try { this.unlink(f.n); } catch {}
          return ok();
        }
        case T.remove: {
          const id = u32();
          const f = this.fids.get(id);
          this.fids.delete(id);
          if (!f) throw new Fail('unknown fid');
          this.unlink(f.n);
          return ok();
        }
        case T.stat: {
          const s = this.stat(fid().n);
          return ok(new Out().u16(s.length).bytes(s));
        }
        case T.wstat: {
          const f = fid();
          u16(); u16(); u16(); u32(); p += 13;
          const mode = u32();
          u32();
          const mtime = u32(), length = u64(), name = str();
          const n = f.n;
          if (name !== '' && name !== n.name) {
            if (n === this.t.root || name.includes('/')) throw new Fail('bad file name');
            if (n.parent.kids.has(name)) throw new Fail('file exists');
          }
          if (length < 2 ** 53 && !n.kids) { // ~0 is don't-touch
            const nd = new Uint8Array(length);
            nd.set(n.data.subarray(0, length));
            n.data = nd;
            this.touch(n);
          }
          if (mode !== NOINT) n.perm = mode & 0o777;
          if (mtime !== NOINT) n.mtime = mtime;
          if (name !== '' && name !== n.name) {
            n.parent.kids.delete(n.name);
            n.name = name;
            n.parent.kids.set(name, n);
            this.touch(n.parent);
          }
          return ok();
        }
        default: throw new Fail('bad message');
      }
    } catch (e) {
      return new Out().str(e instanceof Fail ? e.message : (e?.message ?? 'error')).msg(Rerror, tag);
    }
  }
}
