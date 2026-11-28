(function(){
'use strict';
/* Engine controllers — renderer side. Engine semantics mirror the Dart
 * backends in win-work/app/lib (xray/psiphon/openvpn/warp/lantern platform
 * _windows.dart); process + TUN ownership belongs to the Go service, reached
 * only through window.ember.call (named-pipe IPC, protocol v=1).
 * The service is the single source of truth: no fake connected states.
 *
 * Repair 2042 changes:
 *  - B-1: config-fed processes use the service's real flow —
 *    proc.start{stdin:true} → proc.write{name,line} per line →
 *    proc.close-stdin{name}. Config text is never sent as `stdin`.
 *  - H-6: 'Connected' is earned, never assumed from a spawn. After the
 *    stdin close, proc.state must show the child running AND, for
 *    SOCKS-serving engines, window.ember.tcpPing(127.0.0.1, socksPort)
 *    must answer within ~15 s. Mozilla is verified by proc.state only.
 *  - WireGuard + WARP run on the service's wg.* driver
 *    (wg.start{name, confText} / wg.stop{name} / wg.state{name}); a
 *    wg.state error (e.g. unknown method) is surfaced, never faked.
 *  - EmberWarp's core pick is read at CONNECT time from
 *    window.__emberSettings, not at construction.
 * Adversarial fix round (2042 review):
 *  - C4: 'Disconnected' never reads as connected — parseStage checks
 *    it first, and liveness is exact-word equality (isConnectedWord)
 *    everywhere; Lantern connect has no Connected-on-error fallback.
 *  - W2: a tun.start must be followed by tun.state reporting 'up'
 *    (waitTunUp) before 'Connected' is earned.
 *  - W3: reconcile() adopts service-held engines at boot, with the
 *    same proofs as a fresh connect.
 *  - W5: WireGuard tunnels carry the selected profile's sanitised
 *    name; wg.stop errors surface instead of being swallowed. */

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
// verifySocks: the engine serves SOCKS on socksPort, so 'Connected'
// requires a real TCP answer there. Mozilla serves no SOCKS we may
// claim — it is verified by proc.state only.
const ENGINE_CFG = {
  v2ray:    { proc: 'xray',       folder: 'xray',      exe: 'xray.exe',             args: ['run', '-config', 'stdin:'], socksPort: 10808, verifySocks: true },
  mozilla:  { proc: 'mozilla',    folder: 'core',      exe: 'firefox-vpn-core.exe', args: [],                          socksPort: 10810, verifySocks: false },
  psiphon:  { proc: 'psiphon',    folder: 'psiphon',   exe: 'psiphon-core.exe',     args: [],                          socksPort: 10811, verifySocks: true },
  openvpn:  { proc: 'openvpn',    folder: 'openvpn',   exe: 'openvpn.exe',          args: [],                          socksPort: 0, verifySocks: false },
  singbox:  { proc: 'singbox',    folder: 'singbox',   exe: 'sing-box.exe',         args: ['run', '-c', 'config.json'],socksPort: 20862, verifySocks: true },
  usque:    { proc: 'usque',      folder: 'usque',     exe: 'usque.exe',            args: [],                          socksPort: 10812, verifySocks: true }, // args built in WarpEngine.start (register + -c + socks)
  aether:   { proc: 'aether',     folder: 'aether',    exe: 'aether.exe',           args: [],                          socksPort: 10813, verifySocks: true },
  lantern:  { proc: 'lanternd',   folder: 'lantern',   exe: 'lanternd.exe',         args: [],                          socksPort: 0, verifySocks: false },
};
const TUN_EXE = 'ember-tun-bridge.exe'; // lives in core\ beside firefox-vpn-core.exe
const STAGES = ['starting', 'registering', 'connecting', 'connected', 'reconnecting', 'disconnected', 'failed'];
const VERIFY_TIMEOUT_MS = 15000;
const TUN_VERIFY_TIMEOUT_MS = 10000;

/* The ONLY test for "this engine is live": the state word must be
 * exactly 'Connected' (case-insensitive equality). A substring or
 * regex test is forbidden here — 'Disconnected' contains
 * 'connected' and must never read as live (audit C4). */
function isConnectedWord(word) {
  return String(word || '').trim().toLowerCase() === 'connected';
}

// Stage vocabulary parser for usque/aether stdout (our own parser).
function parseStage(line) {
  const l = String(line || '').toLowerCase();
  // 'disconnected' is checked BEFORE 'connected': it contains the
  // substring, and a down line must map to a DOWN stage (audit C4).
  if (/disconnect|tunnel down|session (ended|closed|terminated)/.test(l)) return 'disconnected';
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
  anyLive() { return Object.values(this.map).some(isConnectedWord); }
}
const engineState = new EngineState();

async function svc(method, params) { return window.ember.call(method, params); }

/* Feed a config text to a just-started proc, line by line, then close
 * its stdin — the service's config-fed flow (B-1). */
async function feedConfig(name, configText) {
  const lines = String(configText).replace(/\r\n/g, '\n').split('\n');
  for (const line of lines) await svc('proc.write', { name, line });
  await svc('proc.close-stdin', { name });
}

/* Poll proc.state until the child reports running. A child that has
 * already exited (running:false with an exit code) fails fast. */
async function waitProcRunning(name, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await svc('proc.state', { name });
    if (last && last.running) return last;
    if (last && last.running === false && (last.exitCode !== undefined && last.exitCode !== null)) {
      throw new Error('process exited during start (code ' + last.exitCode + ')');
    }
    await sleep(400);
  }
  throw new Error('process did not report running within ' + Math.round(timeoutMs / 1000) + ' s');
}

/* Poll the loopback SOCKS port until something accepts a TCP
 * connection there. Uses the main-process bridge
 * window.ember.tcpPing(host, port, timeoutMs) → {ok, ms|error}. */
async function waitSocksAnswer(port, timeoutMs) {
  if (!window.ember || typeof window.ember.tcpPing !== 'function') {
    throw new Error('tcpPing bridge unavailable — cannot verify the SOCKS port');
  }
  const deadline = Date.now() + timeoutMs;
  let lastErr = 'no answer';
  while (Date.now() < deadline) {
    const r = await window.ember.tcpPing('127.0.0.1', port, 1500).catch(e => ({ ok: false, error: String(e.message || e) }));
    if (r && r.ok) return r;
    if (r && r.error) lastErr = r.error;
    await sleep(400);
  }
  throw new Error('SOCKS port ' + port + ' did not answer within ' + Math.round(timeoutMs / 1000) + ' s (' + lastErr + ')');
}

/* Poll tun.state until the bridge session reports 'up' (audit W2):
 * tun.start returning is not proof — the service reports the session
 * 'starting' first, and a bridge that fails to raise the adapter
 * never reaches 'up'. A 'down'/'failed' reading fails fast. */
async function waitTunUp(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await svc('tun.state', {});
    const st = String((last && last.state) || '').toLowerCase();
    if (st === 'up') return last;
    if (st === 'down' || st === 'failed') {
      throw new Error('TUN bridge failed to come up: ' + ((last && last.message) || st));
    }
    await sleep(400);
  }
  throw new Error('TUN bridge did not report up within ' + Math.round(timeoutMs / 1000) +
    ' s (last state: ' + (last ? String(last.state || 'unknown') : 'no answer') + ')');
}

/* Poll wg.state until the tunnel service reports running. Any error
 * from wg.state itself (unknown method included) propagates — the
 * WireGuard state is never invented here. */
async function waitWgRunning(name, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await svc('wg.state', { name });
    if (last && (last.running === true || /^running$/i.test(String(last.state || '')))) return last;
    if (last && /^(stopped|absent|failed|error)$/i.test(String(last.state || '')) && Date.now() > deadline - timeoutMs + 3000) {
      // Give a fresh start a few seconds before treating a stopped
      // reading as final; start_pending etc. keep polling.
      throw new Error('WireGuard tunnel service state: ' + last.state);
    }
    await sleep(500);
  }
  throw new Error('WireGuard tunnel did not reach running within ' + Math.round(timeoutMs / 1000) +
    ' s (last state: ' + (last ? String(last.state || 'unknown') : 'no answer') + ')');
}

class ProcEngine {
  constructor(engine, cfg) { this.engine = engine; this.cfg = cfg; this.running = false; }
  /* start(extraArgs, configText): when configText is given the proc is
   * started with stdin:true and the text is fed via proc.write +
   * proc.close-stdin; without it, no stdin key is sent at all. */
  async start(extraArgs, configText) {
    engineState.set(this.engine, 'Starting');
    const params = { name: this.cfg.proc, exe: exePath(this.cfg.folder, this.cfg.exe),
      args: [...this.cfg.args, ...(extraArgs || [])] };
    if (configText !== undefined && configText !== null) params.stdin = true;
    await svc('proc.start', params);
    if (params.stdin) await feedConfig(this.cfg.proc, configText);
    try {
      await waitProcRunning(this.cfg.proc, 8000);
      if (this.cfg.socksPort) {
        await svc('tun.start', { name: this.cfg.proc, exe: exePath('core', TUN_EXE),
          socksPort: this.cfg.socksPort, skip: [this.cfg.exe] });
        // The TUN session must prove itself up before 'Connected'
        // is earned (audit W2) — for every TUN user, Mozilla
        // included (its only other proof is proc.state).
        await waitTunUp(TUN_VERIFY_TIMEOUT_MS);
        if (this.cfg.verifySocks) await waitSocksAnswer(this.cfg.socksPort, VERIFY_TIMEOUT_MS);
      }
    } catch (e) {
      // Verification failed: tear down what we started so a failed
      // connect never leaves a half-up engine behind, then report.
      try { if (this.cfg.socksPort) await svc('tun.stop', { name: this.cfg.proc }); } catch {}
      try { await svc('proc.stop', { name: this.cfg.proc }); } catch {}
      this.running = false; engineState.set(this.engine, 'Failed');
      throw e;
    }
    this.running = true; engineState.set(this.engine, 'Connected');
  }
  async stop() {
    engineState.set(this.engine, 'Stopping');
    if (this.cfg.socksPort) { try { await svc('tun.stop', { name: this.cfg.proc }); } catch {} }
    try { await svc('proc.stop', { name: this.cfg.proc }); } catch {}
    this.running = false; engineState.set(this.engine, 'Idle');
  }
  async toggle(extraArgs, configText) { return this.running ? this.stop() : this.start(extraArgs, configText); }
}

/* Mirror of the service's awgTunnelNameFor (wg.go): the tunnel
 * service is AmneziaWGTunnel$<name> and the stored config
 * <name>.conf, so the name is kept to letters, digits and `_-.=+`,
 * anything else folds to `_`, capped at 40 chars, leading/trailing
 * `.`/`_` trimmed; an empty result reads 'ember'. The service
 * applies the same fold, so the name we send is the name it uses. */
function sanitizeWgName(name) {
  const folded = String(name || '').replace(/[^A-Za-z0-9_\-.=+]/g, '_').slice(0, 40);
  const trimmed = folded.replace(/^[._]+/, '').replace(/[._]+$/, '');
  return trimmed || 'ember';
}

/* WireGuard engine on the service's wg.* driver: wg.start takes the
 * whole .conf text; state comes only from wg.state. The tunnel's
 * identity is the SELECTED PROFILE's name (audit W5) — a fixed-name
 * engine (WARP) keeps its own name; the profile engine remembers
 * the name it started under (activeName) so stop/state target the
 * same tunnel, never a constant shared by every profile. */
class WgEngine {
  constructor(engine, fixedName) {
    this.engine = engine; this.fixedName = fixedName || null;
    this.activeName = null; this.running = false;
  }
  nameFor(profileName) { return this.fixedName || sanitizeWgName(profileName); }
  currentName() { return this.activeName || this.fixedName || 'ember'; }
  async start(confText, profileName) {
    if (!confText) throw new Error('No WireGuard config selected — import a .conf profile first.');
    const name = this.nameFor(profileName);
    engineState.set(this.engine, 'Connecting');
    try {
      await svc('wg.start', { name, confText });
      await waitWgRunning(name, VERIFY_TIMEOUT_MS);
    } catch (e) {
      this.running = false; engineState.set(this.engine, 'Failed');
      throw e;
    }
    this.activeName = name;
    this.running = true; engineState.set(this.engine, 'Connected');
  }
  async stop() {
    engineState.set(this.engine, 'Stopping');
    // Errors SURFACE (audit W5): a stop the service refused must not
    // be painted as Idle while the tunnel is still up. On failure
    // the engine stays marked running and the caller shows the error.
    await svc('wg.stop', { name: this.currentName() });
    this.activeName = null;
    this.running = false; engineState.set(this.engine, 'Idle');
  }
  async state() { return svc('wg.state', { name: this.currentName() }); }
  async toggle(confText, profileName) { return this.running ? this.stop() : this.start(confText, profileName); }
}

// MASQUE / EmberWarp: usque primary, aether fallback (settings pick).
class WarpEngine extends ProcEngine {
  constructor(engine) {
    // Construction-time pick is only a placeholder: the real core is
    // chosen at CONNECT time in start(), because __emberSettings is
    // not populated until boot() runs (H-6).
    super(engine, ENGINE_CFG.usque); this.stage = 'starting';
  }
  pickCfg() {
    const pick = (window.__emberSettings && window.__emberSettings.emberwarpEngine) || 'usque';
    return ENGINE_CFG[pick] || ENGINE_CFG.usque;
  }
  onOutput(line) { const s = parseStage(line); if (s) { this.stage = s; engineState.set(this.engine, s[0].toUpperCase() + s.slice(1)); } }
  // usque's real CLI shape (v4.2.1): a one-time `register`
  // mints config.json (it carries the device private key —
  // kept under userData, never beside the binary); `socks`
  // then serves loopback SOCKS5 (TCP+UDP) for the TUN bridge.
  async start() {
    this.cfg = this.pickCfg(); // connect-time core pick (H-6)
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
    try {
      await waitProcRunning(this.cfg.proc, 8000);
      await svc('tun.start', { name: this.cfg.proc, exe: exePath('core', TUN_EXE),
        socksPort: this.cfg.socksPort, skip: [this.cfg.exe] });
      await waitTunUp(TUN_VERIFY_TIMEOUT_MS);
      await waitSocksAnswer(this.cfg.socksPort, VERIFY_TIMEOUT_MS);
    } catch (e) {
      try { await svc('tun.stop', { name: this.cfg.proc }); } catch {}
      try { await svc('proc.stop', { name: this.cfg.proc }); } catch {}
      this.running = false; engineState.set(this.engine, 'Failed');
      throw e;
    }
    this.running = true; engineState.set(this.engine, 'Connected');
  }
}

// WARP page: identity minted by the service driver — warp.register {force}
// creates/reuses the WARP WireGuard identity, warp.profile returns the
// canonical profile fields; the profile then runs as a WireGuard tunnel
// through the service's wg.* driver. warp-plus is retired.
function warpConfigFromProfile(p) {
  const addr = [p.addressV4 ? p.addressV4 + '/32' : null, p.addressV6 ? p.addressV6 + '/128' : null]
    .filter(Boolean).join(', ');
  return ['[Interface]', 'PrivateKey = ' + (p.privateKey || ''), 'Address = ' + addr,
    'DNS = 1.1.1.1', '', '[Peer]', 'PublicKey = ' + (p.peerPublicKey || ''),
    'Endpoint = ' + (p.endpoint || ''), 'AllowedIPs = 0.0.0.0/0, ::/0', ''].join('\n');
}
class WarpProfileEngine {
  constructor() { this.engine = 'warp'; this.wg = new WgEngine('warp', 'warp'); this.profile = null; }
  get running() { return this.wg.running; }
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
    const profile = this.profile || await this.register(false);
    engineState.set('warp', 'Connecting');
    await this.wg.start(warpConfigFromProfile(profile));
  }
  async disconnect() { await this.wg.stop(); }
  async toggle() { return this.wg.running ? this.disconnect() : this.connect(); }
}

// OpenVPN: the service's management-interface driver owns the process —
// ovpn.start/state/stop + ovpn.auth for credentials; state arrives as
// unsolicited ovpn.state events (see wireServiceEvents). No raw proc.*.
// The selected profile's configPath is what ovpn.start receives (H-6).
class OpenVpnEngine {
  constructor() { this.engine = 'openvpn'; this.name = 'openvpn'; this.running = false; this.last = null; }
  async start(profile) {
    if (!profile || !profile.configPath) {
      throw new Error('The selected OpenVPN profile has no config file path — import a .ovpn file so its path is known.');
    }
    engineState.set('openvpn', 'Connecting');
    const r = await svc('ovpn.start', { name: this.name,
      exe: exePath(ENGINE_CFG.openvpn.folder, ENGINE_CFG.openvpn.exe),
      configPath: profile.configPath,
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
    // Exact word only (audit C4): the service's vocabulary is
    // idle|starting|connecting|connected|auth|failed|exited, and
    // its `connected` bool is authoritative — never a substring test.
    if (d.connected === true || isConnectedWord(d.state)) { this.running = true; engineState.set('openvpn', 'Connected'); }
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
    try {
      await this.startDaemon();
      if (serverId) await this.call('POST', '/server/selected', { id: serverId });
      const r = await this.call('POST', '/vpn/connect', {});
      // The daemon accepted the connect call; its own status endpoint
      // is the authority for the resulting state word. NO fallback:
      // if the status call fails or carries no word, the connect has
      // no proof — the state is 'Failed' and the error surfaces
      // (audit C4). 'Connected' is set only from the daemon's word,
      // verbatim — including when that word is 'Disconnected'.
      const st = await this.call('GET', '/vpn/status');
      const word = st && (st.state || st.status);
      if (!word) throw new Error('Lantern daemon returned no VPN status after connect — connection unproven.');
      engineState.set('lantern', String(word));
      return r;
    } catch (e) {
      engineState.set('lantern', 'Failed');
      throw e;
    }
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
  wireguard: new WgEngine('wireguard', 'wireguard'),
  emberwarp: new WarpEngine('emberwarp'),
  masque: new WarpEngine('masque'),
  warp: new WarpProfileEngine(),
  lantern: new LanternEngine(),
  urnetwork: new ProcEngine('urnetwork', ENGINE_CFG.v2ray), // managed profiles run via Xray
};

/* Boot reconciliation (audit W3): the service and its children
 * survive an app restart, so at boot the shell adopts what the
 * service actually holds instead of assuming every engine is down.
 * Adoption requires the SAME proofs as a fresh connect — a running
 * proc alone never earns 'Connected'. A child whose proof fails is
 * left running and untouched; its engine simply stays 'Idle' here.
 * opts.wgProfileNames: raw names of the stored WireGuard profiles
 * (app.js owns the profile list; names are sanitised here). */
async function proveProcLive(c) {
  const st = await svc('proc.state', { name: c.cfg.proc });
  if (!st || !st.running) return false;
  if (c.cfg.socksPort) {
    const tun = await svc('tun.state', {});
    if (!tun || String(tun.state || '').toLowerCase() !== 'up') return false;
    if (c.cfg.verifySocks) await waitSocksAnswer(c.cfg.socksPort, 5000);
  }
  return true;
}
async function reconcile(opts) {
  const o = opts || {};
  for (const c of Object.values(controllers)) {
    if (!(c instanceof ProcEngine) || c.running) continue;
    try {
      if (typeof c.pickCfg === 'function') c.cfg = c.pickCfg(); // WarpEngine: connect-time pick
      if (await proveProcLive(c)) { c.running = true; engineState.set(c.engine, 'Connected'); }
    } catch { /* proof failed — leave 'Idle', do not touch the child */ }
  }
  // Lantern: adopt an already-running daemon instead of throwing
  // 'already running' at the user on the first startDaemon call.
  try {
    const lantern = controllers.lantern;
    const st = await lantern.daemonState();
    if (st && st.running) {
      lantern.daemonRunning = true;
      try {
        const vs = await lantern.call('GET', '/vpn/status');
        const word = vs && (vs.state || vs.status);
        if (word) engineState.set('lantern', String(word));
      } catch { /* daemon up, VPN word unknown — engine stays 'Idle' */ }
    }
  } catch { /* no daemon state — nothing to adopt */ }
  // WireGuard tunnels, per name: SCM 'running' IS the proof.
  const wgTargets = [{ engine: controllers.wireguard, names: (o.wgProfileNames || []).map(sanitizeWgName) },
                     { engine: controllers.warp.wg, names: ['warp'] }];
  for (const t of wgTargets) {
    if (!t.engine || t.engine.running) continue;
    for (const name of t.names) {
      try {
        const st = await svc('wg.state', { name });
        if (st && (st.running === true || /^running$/i.test(String(st.state || '')))) {
          t.engine.activeName = name; t.engine.running = true;
          engineState.set(t.engine.engine, 'Connected');
          break;
        }
      } catch { /* unknown name / driver error — not adopted */ }
    }
  }
}

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
window.EmberControllers = { controllers, engineState, wireServiceEvents, ENGINE_CFG, parseStage, isConnectedWord, sanitizeWgName, reconcile, exePath, dirPath, warpConfigFromProfile, feedConfig, waitProcRunning, waitSocksAnswer, waitWgRunning, waitTunUp };

})();
