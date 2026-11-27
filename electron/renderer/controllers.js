(function(){
'use strict';
/* Engine controllers — renderer side. Engine semantics mirror the Dart
 * backends in win-work/app/lib (xray/psiphon/openvpn/warp/lantern platform
 * _windows.dart); process + TUN ownership belongs to the Go service, reached
 * only through window.ember.call (named-pipe IPC, protocol v=1).
 * The service is the single source of truth: no fake connected states. */

// Engine folder layout (packaging contract): in the packaged build the
// engine folders sit BESIDE the app exe under appRoot (core\, xray\, …);
// in dev appRoot is the win-work repo root. window.__appRoot is set from
// app:meta at boot; exe paths are resolved lazily at call time. Before
// boot completes, fall back to the appRoot-relative folder path.
function exePath(folder, exe) {
  const root = window.__appRoot;
  if (!root) return folder + '\\' + exe;
  const sep = root.includes('\\') ? '\\' : '/';
  return root.replace(/[\\/]+$/, '') + sep + folder + sep + exe;
}
function dirPath(folder) {
  const root = window.__appRoot;
  if (!root) return folder;
  const sep = root.includes('\\') ? '\\' : '/';
  return root.replace(/[\\/]+$/, '') + sep + folder;
}
let __metaCache = null;
async function appMeta() { if (!__metaCache) __metaCache = await window.ember.meta(); return __metaCache; }
// Engine-private data (daemon state, usque's config.json with
// its device key) lives under the app's userData, never beside
// the binaries.
async function userDataJoin() {
  const m = await appMeta();
  const base = String(m.userData || '').replace(/[\\/]+$/, '');
  const sep = base.includes('\\') ? '\\' : '/';
  return [base, ...Array.from(arguments)].join(sep);
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Exact flags live in this one config object (engine-build doc contract).
// folder = the engine folder beside the app exe; exe = the binary inside it.
const ENGINE_CFG = {
  v2ray:    { proc: 'xray',       folder: 'xray',      exe: 'xray.exe',             args: ['run', '-config', 'stdin:'], socksPort: 10808 },
  mozilla:  { proc: 'mozilla',    folder: 'core',      exe: 'firefox-vpn-core.exe', args: [],                          socksPort: 10810 },
  psiphon:  { proc: 'psiphon',    folder: 'psiphon',   exe: 'psiphon-core.exe',     args: [],                          socksPort: 10811 },
  openvpn:  { proc: 'openvpn',    folder: 'openvpn',   exe: 'openvpn.exe',          args: [],                          socksPort: 0 },
  wireguard:{ proc: 'wireguard',  folder: 'wireguard', exe: 'amneziawg.exe',        args: [],                          socksPort: 0 },
  singbox:  { proc: 'singbox',    folder: 'singbox',   exe: 'sing-box.exe',         args: ['run', '-c', 'config.json'],socksPort: 20862 },
  usque:    { proc: 'usque',      folder: 'usque',     exe: 'usque.exe',            args: [],                          socksPort: 10812 }, // args built in WarpEngine.start (register + -c + socks)
  aether:   { proc: 'aether',     folder: 'aether',    exe: 'aether.exe',           args: [],                          socksPort: 10813 },
  lantern:  { proc: 'lanternd',   folder: 'lantern',   exe: 'lanternd.exe',         args: [],                          socksPort: 0 },
};
const TUN_EXE = 'ember-tun-bridge.exe'; // lives in core\ beside firefox-vpn-core.exe
const STAGES = ['starting', 'registering', 'connecting', 'connected', 'reconnecting', 'failed'];

// Stage vocabulary parser for usque/aether stdout (our own parser).
function parseStage(line) {
  const l = String(line || '').toLowerCase();
  if (/regist|identity|account/.test(l)) return 'registering';
  if (/connected|tunnel up|session established/.test(l)) return 'connected';
  if (/reconnect|retry|restarting/.test(l)) return 'reconnecting';
  if (/error|fail|fatal|panic/.test(l)) return 'failed';
  if (/connect|handshake|dial/.test(l)) return 'connecting';
  return null;
}

class EngineState {
  constructor() { this.map = {}; this.listeners = []; }
  set(engine, word) {
    const w = String(word || 'Idle');
    if (this.map[engine] === w) return;
    this.map[engine] = w; this.listeners.forEach(f => f(engine, w));
  }
  get(engine) { return this.map[engine] || 'Idle'; }
  on(fn) { this.listeners.push(fn); }
  anyLive() { return Object.values(this.map).some(w => /connected/i.test(w)); }
}
const engineState = new EngineState();

async function svc(method, params) { return window.ember.call(method, params); }

class ProcEngine {
  constructor(engine, cfg) { this.engine = engine; this.cfg = cfg; this.running = false; }
  async start(extraArgs, stdin) {
    engineState.set(this.engine, 'Starting');
    await svc('proc.start', { name: this.cfg.proc, exe: exePath(this.cfg.folder, this.cfg.exe),
      args: [...this.cfg.args, ...(extraArgs || [])], stdin: stdin || '' });
    if (this.cfg.socksPort) {
      await svc('tun.start', { name: this.cfg.proc, exe: exePath('core', TUN_EXE),
        socksPort: this.cfg.socksPort, skip: [this.cfg.exe] });
    }
    this.running = true; engineState.set(this.engine, 'Connected');
  }
  async stop() {
    engineState.set(this.engine, 'Stopping');
    if (this.cfg.socksPort) { try { await svc('tun.stop', { name: this.cfg.proc }); } catch {} }
    try { await svc('proc.stop', { name: this.cfg.proc }); } catch {}
    this.running = false; engineState.set(this.engine, 'Idle');
  }
  async toggle() { return this.running ? this.stop() : this.start(); }
}

// MASQUE / EmberWarp: usque primary, aether fallback (settings pick).
class WarpEngine extends ProcEngine {
  constructor(engine) {
    const pick = (window.__emberSettings && window.__emberSettings.emberwarpEngine) || 'usque';
    super(engine, ENGINE_CFG[pick] || ENGINE_CFG.usque); this.stage = 'starting';
  }
  onOutput(line) { const s = parseStage(line); if (s) { this.stage = s; engineState.set(this.engine, s[0].toUpperCase() + s.slice(1)); } }
  // usque's real CLI shape (v4.2.1): a one-time `register`
  // mints config.json (it carries the device private key —
  // kept under userData, never beside the binary); `socks`
  // then serves loopback SOCKS5 (TCP+UDP) for the TUN bridge.
  async start() {
    if (this.cfg.proc !== 'usque') return super.start();
    const dir = await userDataJoin('usque');
    const sep = dir.includes('\\') ? '\\' : '/';
    const cfgFile = dir + sep + 'config.json';
    if (!(await window.ember.store.get('usqueRegistered'))) {
      engineState.set(this.engine, 'Registering');
      await svc('proc.start', { name: 'usque-register', exe: exePath('usque', 'usque.exe'),
        args: ['-c', cfgFile, 'register'], workDir: dir });
      let code = null;
      for (let i = 0; i < 120; i++) {
        await sleep(500);
        const s = await svc('proc.state', { name: 'usque-register' });
        if (s && !s.running) { code = (s.exitCode === undefined ? null : s.exitCode); break; }
      }
      if (code !== 0) { engineState.set(this.engine, 'Failed'); throw new Error('usque registration did not complete'); }
      await window.ember.store.set('usqueRegistered', true);
    }
    engineState.set(this.engine, 'Starting');
    await svc('proc.start', { name: this.cfg.proc, exe: exePath('usque', 'usque.exe'),
      args: ['-c', cfgFile, 'socks', '-b', '127.0.0.1', '-p', String(this.cfg.socksPort)], workDir: dir });
    await svc('tun.start', { name: this.cfg.proc, exe: exePath('core', TUN_EXE),
      socksPort: this.cfg.socksPort, skip: [this.cfg.exe] });
    this.running = true; engineState.set(this.engine, 'Connected');
  }
}

// WARP page: identity minted by the service driver — warp.register {force}
// creates/reuses the WARP WireGuard identity, warp.profile returns the
// canonical profile fields; the profile then runs through the WireGuard
// engine as an ordinary WG config. warp-plus is retired.
function warpConfigFromProfile(p) {
  const addr = [p.addressV4 ? p.addressV4 + '/32' : null, p.addressV6 ? p.addressV6 + '/128' : null]
    .filter(Boolean).join(', ');
  return ['[Interface]', 'PrivateKey = ' + (p.privateKey || ''), 'Address = ' + addr,
    'DNS = 1.1.1.1', '', '[Peer]', 'PublicKey = ' + (p.peerPublicKey || ''),
    'Endpoint = ' + (p.endpoint || ''), 'AllowedIPs = 0.0.0.0/0, ::/0', ''].join('\n');
}
class WarpProfileEngine {
  constructor() { this.engine = 'warp'; this.wg = new ProcEngine('warp', ENGINE_CFG.wireguard); this.profile = null; }
  async register(force) {
    const reg = await svc('warp.register', { force: !!force });
    let profile = null;
    try { profile = await svc('warp.profile', {}); } catch { profile = null; }
    this.profile = profile || reg;
    await window.ember.store.set('warpProfile', this.profile);
    return this.profile;
  }
  async connect() {
    engineState.set('warp', 'Registering');
    const profile = await this.register(false);
    engineState.set('warp', 'Connecting');
    await this.wg.start([], warpConfigFromProfile(profile));
    engineState.set('warp', 'Connected');
  }
  async disconnect() { await this.wg.stop(); }
}

// OpenVPN: the service's management-interface driver owns the process —
// ovpn.start/state/stop + ovpn.auth for credentials; state arrives as
// unsolicited ovpn.state events (see wireServiceEvents). No raw proc.*.
class OpenVpnEngine {
  constructor() { this.engine = 'openvpn'; this.name = 'openvpn'; this.running = false; this.last = null; }
  async start(profile) {
    engineState.set('openvpn', 'Connecting');
    const r = await svc('ovpn.start', { name: this.name,
      exe: exePath(ENGINE_CFG.openvpn.folder, ENGINE_CFG.openvpn.exe),
      configPath: (profile && profile.configPath) || '',
      workDir: dirPath(ENGINE_CFG.openvpn.folder) });
    this.running = true; return r;
  }
  async stop() {
    try { await svc('ovpn.stop', { name: this.name }); } catch {}
    this.running = false; engineState.set('openvpn', 'Idle');
  }
  async state() { return svc('ovpn.state', { name: this.name }); }
  async auth(username, password) { return svc('ovpn.auth', { name: this.name, username, password }); }
  async toggle(profile) { return this.running ? this.stop() : this.start(profile); }
  onStateEvent(d) {
    this.last = d;
    if (d.connected || /connected/i.test(d.state || '')) { this.running = true; engineState.set('openvpn', 'Connected'); }
    else if (/auth/i.test(d.state || '')) engineState.set('openvpn', 'Needs auth');
    else if (d.state) engineState.set('openvpn', String(d.state));
  }
}

// Lantern: radiance full-VPN owns its TUN — the service daemon driver
// (lantern.start/stop/state) + allow-listed lantern.call endpoints only:
// GET /vpn/status, POST /vpn/connect, POST /vpn/disconnect,
// GET /server/selected, POST /server/selected, GET /servers.
// lantern.call resolves to {status, body}; we surface the daemon's body.
class LanternEngine {
  constructor() { this.engine = 'lantern'; this.daemonRunning = false; }
  async call(method, path, body) {
    const r = await svc('lantern.call', { method, path, body: body || null });
    if (r && typeof r === 'object' && 'status' in r && 'body' in r) {
      if (r.status >= 400) throw new Error('Lantern daemon HTTP ' + r.status);
      return typeof r.body === 'string' ? safeJson(r.body) : r.body;
    }
    return r;
  }
  async startDaemon() {
    if (this.daemonRunning) return;
    // Full-VPN radiance: it owns its TUN (no SOCKS env, no
    // bridge). Data + logs live under userData\lantern; the
    // service adds _LANTERND_CHILD=1 and owns the lifecycle.
    const dataDir = await userDataJoin('lantern');
    const sep = dataDir.includes('\\') ? '\\' : '/';
    await svc('lantern.start', { exe: exePath(ENGINE_CFG.lantern.folder, ENGINE_CFG.lantern.exe),
      args: ['run', '--data-path', dataDir, '--log-path', dataDir + sep + 'logs'],
      env: {}, workDir: dirPath(ENGINE_CFG.lantern.folder) });
    this.daemonRunning = true;
  }
  async stopDaemon() { try { await svc('lantern.stop', {}); } catch {} this.daemonRunning = false; }
  async daemonState() { return svc('lantern.state', {}); }
  async status() { await this.startDaemon(); return this.call('GET', '/vpn/status'); }
  async servers() { await this.startDaemon(); return this.call('GET', '/servers'); }
  async selected() { return this.call('GET', '/server/selected'); }
  async connect(serverId) {
    engineState.set('lantern', 'Connecting');
    await this.startDaemon();
    if (serverId) await this.call('POST', '/server/selected', { id: serverId });
    const r = await this.call('POST', '/vpn/connect', {});
    engineState.set('lantern', 'Connected'); return r;
  }
  async disconnect() { await this.call('POST', '/vpn/disconnect', {}); engineState.set('lantern', 'Idle'); }
  async addPrivateServer() { throw new Error('Private servers are not in the service Lantern API allow-list yet.'); }
  async setSmartRouting() { throw new Error('Smart routing is not in the service Lantern API allow-list yet.'); }
}
function safeJson(s) { try { return JSON.parse(s); } catch { return s; } }

const controllers = {
  v2ray: new ProcEngine('v2ray', ENGINE_CFG.v2ray),
  mozilla: new ProcEngine('mozilla', ENGINE_CFG.mozilla),
  psiphon: new ProcEngine('psiphon', ENGINE_CFG.psiphon),
  openvpn: new OpenVpnEngine(),
  wireguard: new ProcEngine('wireguard', ENGINE_CFG.wireguard),
  emberwarp: new WarpEngine('emberwarp'),
  masque: new WarpEngine('masque'),
  warp: new WarpProfileEngine(),
  lantern: new LanternEngine(),
  urnetwork: new ProcEngine('urnetwork', ENGINE_CFG.v2ray), // managed profiles run via Xray/WG
};

// Service event stream → engine state words + stage parsing.
function wireServiceEvents() {
  window.ember.onEvent(ev => {
    if (!ev || !ev.event) return;
    if (ev.event === 'proc.output') {
      for (const c of Object.values(controllers)) if (c && c.onOutput && ev.data && ev.data.name === (c.cfg || {}).proc) c.onOutput(ev.data.line);
    }
    if (ev.event === 'proc.exit') {
      for (const [name, c] of Object.entries(controllers)) {
        if (c && c.cfg && ev.data && ev.data.name === c.cfg.proc && c.running) {
          c.running = false; engineState.set(name, ev.data.code === 0 ? 'Idle' : 'Failed');
        }
      }
    }
    if (ev.event === 'ovpn.state' && ev.data) controllers.openvpn.onStateEvent(ev.data);
    if (ev.event === 'service.state' && window.__onServiceState) window.__onServiceState(ev.data);
  });
}
window.EmberControllers = { controllers, engineState, wireServiceEvents, ENGINE_CFG, parseStage, exePath, dirPath, warpConfigFromProfile };

})();
