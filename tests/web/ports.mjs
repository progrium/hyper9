// Ports for the [port-streams] integration cases (design/epoch-0/port-streams.md),
// loaded by h9-node through H9_NODE_PORTS. H9_TEST_PORTS lists them,
// separated by `;`:
//
//   NAME=tcp!HOST!PORT[!OPT...]  a port named NAME whose other end is a
//                                Worker relaying it to the 9P server at
//                                HOST!PORT, one 9P message per message
//   serve=tcp!HOST!PORT[!net]    the machine is served: a Worker listens
//                                on HOST!PORT and hands the machine a port
//                                for each connection it accepts, relayed
//                                to it; `net` exports /net too
//
// A relay's options: `text` posts a string in place of the server's
// first answer, and `close=MS` closes the port MS milliseconds after the
// server's first answer, as a Worker that ends does.

import { Worker, MessageChannel, isMainThread, workerData, parentPort } from 'node:worker_threads';
import net from 'node:net';

// Copies a socket's bytes to `port`, one 9P message per message, and
// the port's messages to the socket.
function relay(port, sock, { text = false, close = -1 } = {}) {
  let buf = Buffer.alloc(0);
  let first = true;
  let ended = false;
  const end = (hangup) => {
    if (ended) return;
    ended = true;
    if (hangup) try { port.postMessage(null); } catch {}
    port.close();
    sock.destroy();
  };
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const n = buf.readUInt32LE(0);
      if (buf.length < n) break;
      const msg = new Uint8Array(buf.subarray(0, n));
      buf = buf.subarray(n);
      if (first) {
        first = false;
        if (text) { port.postMessage('not 9P'); continue; }
        if (close >= 0) setTimeout(() => end(false), close);
      }
      port.postMessage(msg.buffer, [msg.buffer]);
    }
  });
  sock.on('close', () => end(true));
  sock.on('error', () => end(true));
  port.on('message', (m) => {
    if (m === null) return end(false);
    sock.write(Buffer.from(m instanceof ArrayBuffer ? new Uint8Array(m) : m));
  });
  port.on('close', () => end(false));
}

function dial(addr) {
  const [, host, p] = addr.split('!');
  return { host, port: Number(p) };
}

if (!isMainThread) {
  const d = workerData;
  if (d.kind === 'dial') {
    const sock = net.connect(dial(d.addr));
    relay(d.port, sock, d.opts);
  } else {
    // Each connection gets a channel of its own; its other end goes to
    // the main thread, which hands it to the machine.
    const srv = net.createServer((sock) => {
      const ch = new MessageChannel();
      relay(ch.port2, sock);
      parentPort.postMessage(ch.port1, [ch.port1]);
    });
    srv.listen(dial(d.addr));
    parentPort.on('message', (m) => { if (m === 'stop') srv.close(() => process.exit(0)); });
  }
}

export default function (ports) {
  const workers = [];
  for (const entry of (process.env.H9_TEST_PORTS ?? '').split(';').filter((x) => x)) {
    const eq = entry.indexOf('=');
    const name = entry.slice(0, eq);
    const [proto, host, p, ...rest] = entry.slice(eq + 1).split('!');
    const addr = `${proto}!${host}!${p}`;
    if (name === 'serve') {
      ports.serving = true;
      ports.serveNet = rest.includes('net');
      const w = new Worker(new URL(import.meta.url), { workerData: { kind: 'listen', addr } });
      w.on('message', (port) => ports.serve(port));
      workers.push(w);
      continue;
    }
    const opts = { text: rest.includes('text'), close: -1 };
    for (const o of rest) if (o.startsWith('close=')) opts.close = Number(o.slice(6));
    const ch = new MessageChannel();
    ports.add(name, ch.port1);
    workers.push(new Worker(new URL(import.meta.url), { workerData: { kind: 'dial', addr, port: ch.port2, opts }, transferList: [ch.port2] }));
  }
  return () => Promise.all(workers.map((w) => w.terminate()));
}
