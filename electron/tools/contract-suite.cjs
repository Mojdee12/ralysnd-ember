'use strict';
/* Contract suite (2042, audit M-1/F1 — the gate 2041 never had).
 *
 * Drives the REAL shell payload shapes against the REAL Go service:
 *   L1 — raw protocol frames over the service's loopback console
 *        listener, including the negative cases (the 2041 string-stdin
 *        payload, allowlist refusal, path traversal, foreign roots).
 *   L2 — the actual renderer code (profiles.js + controllers.js loaded
 *        unmodified) with window.ember.call bridged to the same live
 *        socket: import a link, build the Xray config, connect, and
 *        prove the fake xray.exe received the config verbatim over
 *        stdin, saw EOF, and opened its SOCKS port.
 *
 * Run via run-contract-suite.sh, which builds the fixture. Exit code
 * is the gate: 0 = all green, 1 = any failure. No warn-only paths. */
const net = require('net');
const fs = require('fs');
const path = require('path');

const ADDR = { host: '127.0.0.1', port: 47832 };
const ROOT = process.env.CONTRACT_FIXTURE_ROOT;
const RECEIVED = process.env.CONTRACT_RECEIVED_FILE;
if (!ROOT || !RECEIVED) { console.error('CONTRACT_FIXTURE_ROOT / CONTRACT_RECEIVED_FILE unset'); process.exit(2); }

let failures = 0, count = 0;
function check(name, cond, extra) {
  count++;
  if (cond) console.log('ok ' + count + ' - ' + name);
  else { failures++; console.log('NOT OK ' + count + ' - ' + name + (extra ? ' :: ' + extra : '')); }
}

/* --- pipe client: JSON lines, id-matched, events skipped --- */
class Pipe {
  constructor() { this.buf = ''; this.nextId = 1; this.pending = new Map(); }
  connect() {
    return new Promise((resolve, reject) => {
      this.sock = net.connect(ADDR, resolve);
      this.sock.setEncoding('utf8');
      this.sock.on('data', d => {
        this.buf += d;
        let i;
        while ((i = this.buf.indexOf('\n')) >= 0) {
          const line = this.buf.slice(0, i); this.buf = this.buf.slice(i + 1);
          if (!line.trim()) continue;
          let msg; try { msg = JSON.parse(line); } catch { continue; }
          if (msg.event) continue;                       // event frame
          const p = this.pending.get(msg.id);
          if (p) { this.pending.delete(msg.id); p(msg); }
        }
      });
      this.sock.on('error', reject);
    });
  }
  call(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('timeout: ' + method)); }, 20000);
      this.pending.set(id, msg => { clearTimeout(timer); resolve(msg); });
      this.sock.write(JSON.stringify({ v: 1, id, method, params: params || {} }) + '\n');
    });
  }
  async callOk(method, params) {
    const r = await this.call(method, params);
    if (!r.ok) throw new Error(method + ' failed: ' + (r.error || 'unknown'));
    return r.result;
  }
}

function tcpPing(port) {
  return new Promise(resolve => {
    const s = net.connect({ host: '127.0.0.1', port });
    const done = ok => { try { s.destroy(); } catch {} resolve(ok); };
    s.setTimeout(2000, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function main() {
  const pipe = new Pipe();
  await pipe.connect();
  const exe = path.join(ROOT, 'xray', 'xray.exe');

  /* ---------- L1: raw protocol ---------- */
  const hello = await pipe.call('hello', { appRoot: ROOT });
  check('L1 hello answers ok', hello.ok === true, JSON.stringify(hello));

  const status = await pipe.call('service.status', {});
  check('L1 service.status answers ok', status.ok === true && status.result && typeof status.result === 'object');

  const legacy = await pipe.call('proc.start', { name: 'legacy', exe, args: [], stdin: '{"inbounds":[]}' });
  check('L1 the 2041 string-stdin payload is refused with a clean error frame',
    legacy.ok === false && /unmarshal|stdin/i.test(String(legacy.error || '')), JSON.stringify(legacy));
  const alive = await pipe.call('service.status', {});
  check('L1 service survives the malformed payload', alive.ok === true);

  const notEngine = await pipe.call('proc.start', { name: 'nope', exe: path.join(ROOT, 'xray', 'notanengine.exe'), args: [] });
  check('L1 non-allowlisted exe refused', notEngine.ok === false && /not an Ember engine|not allowed|allowlist/i.test(String(notEngine.error || '')), JSON.stringify(notEngine));

  // W6: the traversal check must isolate CONFINEMENT — an allowlisted name
  // (xray.exe) that canonicalises OUTSIDE the root. A non-allowlisted name
  // would be refused by the allowlist and prove nothing about confinement.
  fs.mkdirSync(path.join(ROOT, '..', 'contract-outside'), { recursive: true });
  const travExe = path.join(ROOT, 'xray', '..', '..', 'contract-outside', 'xray.exe');
  const traversal = await pipe.call('proc.start', { name: 'trav', exe: travExe, args: [] });
  check('L1 traversal (allowlisted name, outside root) refused', traversal.ok === false, JSON.stringify(traversal));
  check('L1 traversal refusal cites confinement, not the allowlist',
    /outside (the app root|every registered app folder)/i.test(String(traversal.error || '')), String(traversal.error || ''));

  const foreign = path.join('/tmp', 'contract-foreign-root');
  await pipe.call('hello', { appRoot: foreign });
  const foreignStart = await pipe.call('proc.start', { name: 'frn', exe: path.join(foreign, 'xray.exe'), args: [] });
  check('L1 hello cannot register a foreign root (B-S1 lock)', foreignStart.ok === false, JSON.stringify(foreignStart));

  const closeGhost = await pipe.call('proc.close-stdin', { name: 'never-started' });
  check('L1 proc.close-stdin on unknown name errors cleanly', closeGhost.ok === false, JSON.stringify(closeGhost));

  const wgGhost = await pipe.call('wg.state', { name: 'ghost' });
  check('L1 wg.state answers for an absent tunnel (no fake state, no crash)',
    wgGhost.ok === true && wgGhost.result && typeof wgGhost.result.state === 'string', JSON.stringify(wgGhost));

  const unknown = await pipe.call('nope.nope', {});
  check('L1 unknown method refused', unknown.ok === false && /unknown method/i.test(String(unknown.error || '')), JSON.stringify(unknown));

  /* ---------- L2: the real renderer code ---------- */
  const calls = [];
  const rawCall = pipe.callOk.bind(pipe);
  global.window = {
    __appRoot: ROOT,
    __emberSettings: { emberwarpEngine: 'usque' },
    ember: {
      call: async (method, params) => { calls.push({ method, params }); return rawCall(method, params); },
      tcpPing: async (host, port) => ({ ok: await tcpPing(port) }),
      onEvent: () => {},
      meta: async () => ({ version: '2.2.0' }),
    },
  };
  const rendererDir = path.join(__dirname, '..', 'renderer');
  eval(fs.readFileSync(path.join(rendererDir, 'profiles.js'), 'utf8'));
  eval(fs.readFileSync(path.join(rendererDir, 'controllers.js'), 'utf8'));
  const EP = global.window.EmberProfiles;
  const EC = global.window.EmberControllers;
  check('L2 renderer modules load', !!EP && !!EC && !!EC.controllers.v2ray);

  const link = 'vless://11111111-2222-3333-4444-555555555555@example.invalid:443' +
    '?encryption=none&security=tls&sni=example.invalid#ContractTest';
  const profile = EP.parseLink(link);
  check('L2 parseLink(vless) yields a profile', !!profile && profile.protocol === 'vless', JSON.stringify(profile));
  const config = EP.buildXrayConfig(profile, { socksPort: 10808 });
  const configText = JSON.stringify(config, null, 1);
  check('L2 buildXrayConfig yields SOCKS 10808 + vless outbound',
    config.inbounds.some(i => i.port === 10808 && i.protocol === 'socks') &&
    config.outbounds.some(o => o.protocol === 'vless'));

  calls.length = 0;
  await EC.controllers.v2ray.start([], configText);
  check('L2 real ProcEngine.start reaches Connected against the real service',
    EC.engineState.get('v2ray') === 'Connected', 'state=' + EC.engineState.get('v2ray'));

  const startCall = calls.find(c => c.method === 'proc.start');
  check('L2 proc.start carried stdin as boolean true (never config text)',
    !!startCall && startCall.params.stdin === true, JSON.stringify(startCall && startCall.params));
  const writeCalls = calls.filter(c => c.method === 'proc.write');
  const closeCalls = calls.filter(c => c.method === 'proc.close-stdin');
  check('L2 config fed via proc.write lines then proc.close-stdin exactly once',
    writeCalls.length === configText.split('\n').length && closeCalls.length === 1,
    'writes=' + writeCalls.length + ' closes=' + closeCalls.length);

  await sleep(300);
  const received = fs.existsSync(RECEIVED) ? fs.readFileSync(RECEIVED, 'utf8') : '';
  check('L2 fake xray received the config verbatim over stdin (EOF reached)',
    received.replace(/\r\n/g, '\n').replace(/\n$/, '') === configText.replace(/\n$/, ''), 'received ' + received.length + ' bytes');

  check('L2 SOCKS port 10808 answers', await tcpPing(10808));

  const tunState = await pipe.callOk('tun.state', {}).catch(() => null);
  check('L2 tun.state reports the bridge session up after connect',
    !!tunState && (tunState.up === true || tunState.state === 'up' || (Array.isArray(tunState.sessions) && tunState.sessions.some(s => s.up || s.state === 'up'))),
    JSON.stringify(tunState));

  await EC.controllers.v2ray.stop();
  let stopped = false;
  for (let i = 0; i < 15 && !stopped; i++) {
    const st = await pipe.callOk('proc.state', { name: 'xray' }).catch(() => null);
    if (st && st.running === false) stopped = true; else await sleep(400);
  }
  check('L2 stop() leaves the child not running', stopped);

  // C4 locks: the word 'Disconnected' must never satisfy a liveness test.
  check('L2 isConnectedWord uses exact equality (Disconnected is not Connected)',
    typeof EC.isConnectedWord === 'function' &&
    EC.isConnectedWord('Disconnected') === false && EC.isConnectedWord('Connected') === true &&
    EC.isConnectedWord(' disconnected ') === false);
  EC.engineState.set('warp', 'Disconnected');
  check('L2 EngineState.anyLive is false when the only live-ish word is Disconnected',
    EC.engineState.anyLive() === false);
  EC.engineState.set('warp', 'Idle');

  const wgConf = '[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress = 10.0.0.2/32\n' +
    '[Peer]\nPublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\nEndpoint = 127.0.0.1:51820\nAllowedIPs = 0.0.0.0/0\n';
  let wgError = null;
  try { await EC.controllers.wireguard.start(wgConf); } catch (e) { wgError = e; }
  check('L2 WireGuard start on a host without the tunnel tooling fails honestly (never Connected)',
    !!wgError && EC.engineState.get('wireguard') !== 'Connected',
    wgError ? String(wgError.message || wgError) : 'no error thrown');

  console.log('---');
  console.log(count + ' checks, ' + failures + ' failures');
  process.exit(failures ? 1 : 0);
}

main().catch(e => { console.error('SUITE ERROR:', e); process.exit(1); });
