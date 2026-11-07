// WASI for the browser host (design/0012-browser-host.md): the calls
// h9.wasm makes, over an in-memory tree loaded from the root archive that
// `zig build web` makes (tools/webroot.zig). The tree is preopened at /
// and read-only: the guest's writes go to h9's overlay, in memory. Output
// on fds 1 and 2 goes to `write(fd, bytes)`.

const E = {
  SUCCESS: 0, BADF: 8, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44,
  NOSYS: 52, NOTDIR: 54, ROFS: 69, SPIPE: 70,
};
const FT = { CHAR: 2, DIR: 3, FILE: 4 };
const S_IFDIR = 0o040000;
const RIGHTS = 0x1fffffffn;
const PREOPEN = 3;

/** Parses a root archive into a tree of { dir, mode, data, kids, ino }. */
export function parseRoot(buf) {
  const b = new Uint8Array(buf);
  const magic = new TextDecoder().decode(b.subarray(0, 8));
  if (magic !== 'h9root1\n') throw new Error('not an h9 root archive');
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let ino = 1;
  const root = { dir: true, mode: S_IFDIR | 0o775, kids: new Map(), ino: ino++ };
  const dec = new TextDecoder();
  let i = 8;
  while (i < b.length) {
    const n = dv.getUint32(i, true); i += 4;
    const path = dec.decode(b.subarray(i, i + n)); i += n;
    const mode = dv.getUint32(i, true); i += 4;
    const size = dv.getUint32(i, true); i += 4;
    const data = b.subarray(i, i + size); i += size;
    const parts = path.split('/');
    let d = root;
    for (const p of parts.slice(0, -1)) {
      let k = d.kids.get(p);
      if (!k) { k = { dir: true, mode: S_IFDIR | 0o775, kids: new Map(), ino: ino++ }; d.kids.set(p, k); }
      d = k;
    }
    const name = parts[parts.length - 1];
    const dir = (mode & 0o170000) === S_IFDIR;
    const old = d.kids.get(name);
    if (old && dir) continue;
    d.kids.set(name, dir ? { dir, mode, kids: new Map(), ino: ino++ } : { dir, mode, data, ino: ino++ });
  }
  return root;
}

/**
 * The wasi_snapshot_preview1 imports over `memory`: `root` from
 * parseRoot, `args` and `env` (an object) for the program.
 */
export function wasiImports({ memory, root, args, env, write }) {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const u8 = () => new Uint8Array(memory.buffer);
  const dv = () => new DataView(memory.buffer);
  const str = (p, n) => dec.decode(new Uint8Array(memory.buffer, p >>> 0, n >>> 0));
  // Open files: { node, path, pos }. 0..2 are the console.
  const fds = new Map([[PREOPEN, { node: root, path: '', pos: 0 }]]);
  let nextFd = PREOPEN + 1;

  const resolve = (base, rel) => {
    const out = base ? base.split('/') : [];
    for (const p of rel.split('/')) {
      if (p === '' || p === '.') continue;
      if (p === '..') out.pop(); else out.push(p);
    }
    return out.join('/');
  };
  const lookup = (path) => {
    let n = root;
    if (path === '') return n;
    for (const p of path.split('/')) {
      if (!n.dir) return null;
      n = n.kids.get(p);
      if (!n) return null;
    }
    return n;
  };
  const at = (fd, p, n) => {
    const d = fds.get(fd);
    if (!d || !d.node.dir) return [d ? E.NOTDIR : E.BADF];
    const path = resolve(d.path, str(p, n));
    const node = lookup(path);
    return node ? [E.SUCCESS, node, path] : [E.NOENT];
  };
  const filestat = (ptr, node) => {
    const v = dv();
    v.setBigUint64(ptr, 1n, true);
    v.setBigUint64(ptr + 8, BigInt(node.ino), true);
    v.setUint8(ptr + 16, node.dir ? FT.DIR : FT.FILE);
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(node.dir ? 0 : node.data.length), true);
    v.setBigUint64(ptr + 40, 0n, true);
    v.setBigUint64(ptr + 48, 0n, true);
    v.setBigUint64(ptr + 56, 0n, true);
    return E.SUCCESS;
  };
  const iovs = (p, n) => {
    const v = dv();
    const out = [];
    for (let k = 0; k < n; k++) out.push(new Uint8Array(memory.buffer, v.getUint32(p + 8 * k, true), v.getUint32(p + 8 * k + 4, true)));
    return out;
  };
  const readAt = (node, list, pos) => {
    let n = 0;
    for (const v of list) {
      const src = node.data.subarray(pos + n, pos + n + v.length);
      v.set(src);
      n += src.length;
      if (src.length < v.length) break;
    }
    return n;
  };
  const strings = (list) => list.map((s) => enc.encode(s + '\0'));
  const argv = strings(args);
  const envv = strings(Object.entries(env).map(([k, v]) => `${k}=${v}`));
  const sizes = (list, pc, ps) => {
    dv().setUint32(pc, list.length, true);
    dv().setUint32(ps, list.reduce((a, s) => a + s.length, 0), true);
    return E.SUCCESS;
  };
  const fill = (list, pp, pb) => {
    for (const s of list) {
      dv().setUint32(pp, pb, true);
      u8().set(s, pb);
      pp += 4;
      pb += s.length;
    }
    return E.SUCCESS;
  };

  return {
    args_sizes_get: (pc, ps) => sizes(argv, pc, ps),
    args_get: (pp, pb) => fill(argv, pp, pb),
    environ_sizes_get: (pc, ps) => sizes(envv, pc, ps),
    environ_get: (pp, pb) => fill(envv, pp, pb),
    clock_res_get: (_id, p) => { dv().setBigUint64(p, 1000n, true); return E.SUCCESS; },
    clock_time_get: (id, _prec, p) => {
      const ms = id === 0 ? Date.now() : performance.now();
      dv().setBigUint64(p, BigInt(Math.round(ms * 1e6)), true);
      return E.SUCCESS;
    },
    random_get: (p, n) => {
      for (let k = 0; k < n; k += 65536) crypto.getRandomValues(new Uint8Array(memory.buffer, p + k, Math.min(65536, n - k)));
      return E.SUCCESS;
    },
    fd_prestat_get: (fd, p) => {
      if (fd !== PREOPEN) return E.BADF;
      dv().setUint8(p, 0);
      dv().setUint32(p + 4, 1, true);
      return E.SUCCESS;
    },
    fd_prestat_dir_name: (fd, p, n) => {
      if (fd !== PREOPEN) return E.BADF;
      if (n >= 1) u8()[p] = 0x2f; // "/"
      return E.SUCCESS;
    },
    fd_fdstat_get: (fd, p) => {
      const v = dv();
      let ft;
      if (fd <= 2) ft = FT.CHAR;
      else { const d = fds.get(fd); if (!d) return E.BADF; ft = d.node.dir ? FT.DIR : FT.FILE; }
      v.setUint8(p, ft);
      v.setUint16(p + 2, 0, true);
      v.setBigUint64(p + 8, RIGHTS, true);
      v.setBigUint64(p + 16, RIGHTS, true);
      return E.SUCCESS;
    },
    fd_filestat_get: (fd, p) => {
      if (fd <= 2) {
        new Uint8Array(memory.buffer, p, 64).fill(0);
        dv().setUint8(p + 16, FT.CHAR);
        return E.SUCCESS;
      }
      const d = fds.get(fd);
      return d ? filestat(p, d.node) : E.BADF;
    },
    path_filestat_get: (fd, _flags, p, n, out) => {
      const [e, node] = at(fd, p, n);
      return e || filestat(out, node);
    },
    path_open: (fd, _dirflags, p, n, oflags, _rb, _ri, _fdflags, out) => {
      const [e, node, path] = at(fd, p, n);
      if (e) return e === E.NOENT && (oflags & 1) ? E.ROFS : e;
      if ((oflags & 2) && !node.dir) return E.NOTDIR;
      if (oflags & (4 | 8)) return (oflags & 4) ? E.EXIST : E.ROFS;
      const nfd = nextFd++;
      fds.set(nfd, { node, path, pos: 0 });
      dv().setUint32(out, nfd, true);
      return E.SUCCESS;
    },
    fd_close: (fd) => (fds.delete(fd) || fd <= 2 ? E.SUCCESS : E.BADF),
    fd_read: (fd, p, n, out) => {
      if (fd === 0) { dv().setUint32(out, 0, true); return E.SUCCESS; }
      const d = fds.get(fd);
      if (!d) return E.BADF;
      if (d.node.dir) return E.ISDIR;
      const got = readAt(d.node, iovs(p, n), d.pos);
      d.pos += got;
      dv().setUint32(out, got, true);
      return E.SUCCESS;
    },
    fd_pread: (fd, p, n, off, out) => {
      const d = fds.get(fd);
      if (!d) return E.BADF;
      if (d.node.dir) return E.ISDIR;
      dv().setUint32(out, readAt(d.node, iovs(p, n), Number(off)), true);
      return E.SUCCESS;
    },
    fd_write: (fd, p, n, out) => {
      if (fd !== 1 && fd !== 2) return fds.has(fd) ? E.ROFS : E.BADF;
      let total = 0;
      for (const v of iovs(p, n)) { if (v.length) write(fd, v.slice()); total += v.length; }
      dv().setUint32(out, total, true);
      return E.SUCCESS;
    },
    fd_pwrite: (fd) => (fds.has(fd) ? E.ROFS : E.BADF),
    fd_seek: (fd, off, whence, out) => {
      const d = fds.get(fd);
      if (!d) return fd <= 2 ? E.SPIPE : E.BADF;
      const size = d.node.dir ? 0 : d.node.data.length;
      const pos = [0, d.pos, size][whence] + Number(off);
      if (pos < 0 || whence > 2) return E.INVAL;
      d.pos = pos;
      dv().setBigUint64(out, BigInt(pos), true);
      return E.SUCCESS;
    },
    fd_readdir: (fd, p, len, cookie, out) => {
      const d = fds.get(fd);
      if (!d) return E.BADF;
      if (!d.node.dir) return E.NOTDIR;
      const names = ['.', '..', ...d.node.kids.keys()];
      const buf = new Uint8Array(len);
      let used = 0;
      for (let k = Number(cookie); k < names.length && used < len; k++) {
        const name = enc.encode(names[k]);
        const kid = k < 2 ? d.node : d.node.kids.get(names[k]);
        const ent = new Uint8Array(24 + name.length);
        const ev = new DataView(ent.buffer);
        ev.setBigUint64(0, BigInt(k + 1), true);
        ev.setBigUint64(8, BigInt(kid.ino), true);
        ev.setUint32(16, name.length, true);
        ev.setUint8(20, kid.dir ? FT.DIR : FT.FILE);
        ent.set(name, 24);
        const m = Math.min(ent.length, len - used);
        buf.set(ent.subarray(0, m), used);
        used += m;
      }
      u8().set(buf.subarray(0, used), p);
      dv().setUint32(out, used, true);
      return E.SUCCESS;
    },
    path_readlink: (fd, p, n) => { const [e] = at(fd, p, n); return e || E.INVAL; },
    // Nothing can block here; h9 waits in its own coroutines.
    poll_oneoff: (inp, outp, nsubs, nout) => {
      const v = dv();
      for (let k = 0; k < nsubs; k++) {
        v.setBigUint64(outp + 32 * k, v.getBigUint64(inp + 48 * k, true), true);
        v.setUint16(outp + 32 * k + 8, 0, true);
        v.setUint8(outp + 32 * k + 10, v.getUint8(inp + 48 * k + 8));
      }
      v.setUint32(nout, nsubs, true);
      return E.SUCCESS;
    },
    fd_sync: () => E.SUCCESS,
    fd_filestat_set_size: () => E.ROFS,
    fd_filestat_set_times: () => E.ROFS,
    path_filestat_set_times: () => E.ROFS,
    path_create_directory: () => E.ROFS,
    path_remove_directory: () => E.ROFS,
    path_unlink_file: () => E.ROFS,
    path_rename: () => E.ROFS,
    path_link: () => E.ROFS,
    path_symlink: () => E.ROFS,
    proc_exit: (code) => { throw new Error(`exit ${code}`); },
  };
}
