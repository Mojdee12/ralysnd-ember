'use strict';
/* Ralysnd Ember — Electron main process.
 * Pure client of the Go Windows service (named pipe \\.\pipe\RalysndEmberService.v1,
 * JSON lines, protocol v=1). No engine logic lives here beyond the IPC client,
 * the persistent store, the safeStorage secret vault and the updater guard. */
const { app, BrowserWindow, Tray, Menu, ipcMain, safeStorage, shell, nativeImage, screen, dialog, session, globalShortcut } = require('electron');
const net = require('net');
const fs = require('fs');
const path = require('path');
const https = require('https');
const { spawn } = require('child_process');
if (process.env.EMBER_NO_SANDBOX === '1') app.commandLine.appendSwitch('no-sandbox');

const PIPE = '\\\\.\\pipe\\RalysndEmberService.v1';
const SHOOT = process.argv.includes('--shoot') || process.env.EMBER_SHOOT === '1';

/* ---------- paths ----------
 * Packaged layout (Inno installer): the app exe ("Ralysnd Ember.exe") sits
 * in the install folder and the engine folders live BESIDE it, exactly as
 * the 2040 package: core\ xray\ psiphon\ aether\ usque\ openvpn\ wireguard\
 * lantern\ singbox\ sudokubox\ zapret\ mieru\ dnscrypt\ dnstt\ wstunnel\
 * olcrtc\. So appRoot = the folder containing the app exe.
 * Dev layout: appRoot = the win-work repo root (electron/'s parent), where
 * core\ is built by the Go toolchain. */
function appRoot() {
  return app.isPackaged ? path.dirname(process.execPath) : path.join(__dirname, '..');
}
const ENGINE_FOLDERS = ['core', 'xray', 'psiphon', 'aether', 'usque', 'openvpn',
  'wireguard', 'lantern', 'singbox', 'sudokubox', 'zapret', 'mieru', 'dnscrypt',
  'dnstt', 'wstunnel', 'olcrtc'];
function engineDir(folder) { return path.join(appRoot(), folder); }
function enginePath(folder, exe) { return path.join(engineDir(folder), exe); }
function coreDir() { return engineDir('core'); }

/* User data location (installer contract): the packaged build keeps its
 * data in a `user-data` folder BESIDE the installed app (Inno offers to
 * keep it on uninstall). Must be set before app ready, before any
 * getPath('userData') call — the store and the secret vault both live
 * under userData. Dev runs keep Electron's default userData. */
if (app.isPackaged) {
  try { app.setPath('userData', path.join(appRoot(), 'user-data')); } catch {}
}

/* ---------- persistent store (atomic write) ---------- */
const DEFAULT_STATE = {
  version: 1,
  selectedEngine: 'mozilla',
  profiles: [],            // {id,name,protocol,address,port,security,engine,group}
  subscriptions: [],       // {id,name,url,updatedAt}
  selectedProfileId: null,
  settings: {
    // Every Ember-added feature ships DEFAULT OFF (owner law).
    smartRouting: false, killSwitch: false, autoConnect: false,
    byedpiHop: false, dailyProblemReport: false, appLock: false,
    connectedButBlocked: true, // consumer: app.js blockedWatcher (owner's 2151 exception — DEFAULT ON)
    sessionBudget: false, batteryReport: false, leakTestOnConnect: false,
    tunMode: true, systemProxy: false,
    startOnBoot: false, closeToTray: false,   // side effects applied in main (see applySettingsSideEffects)
    emberwarpEngine: 'usque',           // 'usque' (primary) | 'aether' (fallback)
    // Renderer-consumed keys (2042 settings data layer): sniffing follows
    // v2rayNG's default (on, http/tls), the rest are Ember features and
    // therefore DEFAULT OFF / neutral per the owner's law.
    sniffing: true, fakeDns: false,
    routingPreset: 'global', domainStrategy: 'IPIfNonMatch',
    // DNS defaults = v2rayNG's own, verbatim.
    remoteDns: 'https://dns.google/dns-query',
    localDns: '8.8.8.8',
    socksPort: 10808,
    // 2042 Phase 3 (UI-S-A foundations). Every key below names its
    // real consumer; a key with no consumer is not added (see the
    // phase report's remainder list). Ember-added features stay
    // DEFAULT OFF; DNS/LAN defaults stay v2rayNG's.
    dnsPreset: 'google',        // 'google' | 'cloudflare' | 'custom' — consumer: profiles.js resolveDnsServers (preset 'google' + transport 'doh' resolves to the remoteDns default above, so the default config is unchanged)
    dnsTransport: 'doh',        // 'doh' | 'udp' | 'tcp' — consumer: profiles.js resolveDnsServers
    listenAddress: '127.0.0.1', // consumer: profiles.js buildXrayConfig (SOCKS inbound listen when lanSharing is off)
    lanSharing: false,          // consumer: profiles.js buildXrayConfig (inbound listen 0.0.0.0 + optional auth)
    lanAuthUser: '',            // consumer: profiles.js buildXrayConfig (SOCKS accounts when lanSharing). The LAN PASSWORD is a credential: it lives ONLY in the safeStorage vault under the secret key 'lanAuthPass' (secret:set/get bridge) and is deliberately NOT a settings key.
    regionHopEnabled: false,    // consumer: controllers.js RegionHopController (gates profile creation)
    dpiLabEnabled: false,       // consumer: controllers.js ByeDpiController (gates ciadpi start)
    // 2042 Phase 3 UI-S-B2 keys. Ember-added features stay DEFAULT
    // OFF; the one exception is trafficAccounting, which defaults
    // TRUE because it matches v2rayNG/Android behaviour (the
    // Android builder always emits stats + policy) — ruling
    // documented again at its consumer in profiles.js.
    trafficAccounting: true,    // consumer: profiles.js buildXrayConfig (stats/policy/metrics inbound)
    sessionBudgetMb: 0,         // consumer: app.js traffic loop (0 = no budget; >0 disconnects past the budget)
    sweepAutoCut: false,        // consumer: app.js pingAllProfiles (quarantine after failStreak >= sweepThreshold)
    sweepThreshold: 3,          // consumer: app.js pingAllProfiles
    subscriptionAutoUpdate: false, // consumer: app.js boot (refetch stale subscriptions on launch)
    subRefreshHours: 24,        // consumer: app.js boot subscription refresh interval
    hwid: '',                   // consumer: app.js importSubscription (default x-hwid for new subscriptions; per-subscription hwid wins)
    globalShortcut: false,      // consumer: main applyShortcut (Ctrl+Alt+E toggles connect) + app.js onShortcutToggle
  },
  engineSettings: {},      // per-engine bags, all feature flags default OFF
  urnetworkAccounts: [],   // {id,label} — API keys live ONLY in the secret vault
  lantern: { privateServers: [], selectedServer: null },
  warpProfile: null,       // filled by warp.register via the service
  lastDailyReportDate: '', // UI-S-B2 task 6: date (YYYY-MM-DD) of the last daily problem report written by main (ember:saveDailyReport); renderer-owned bookkeeping, no secret content
};
let stateCache = null;
function stateFile() { return path.join(app.getPath('userData'), 'ember-state.json'); }
function loadState() {
  if (stateCache) return stateCache;
  try { stateCache = Object.assign({}, DEFAULT_STATE, JSON.parse(fs.readFileSync(stateFile(), 'utf8'))); }
  catch { stateCache = JSON.parse(JSON.stringify(DEFAULT_STATE)); }
  stateCache.settings = Object.assign({}, DEFAULT_STATE.settings, stateCache.settings || {});
  return stateCache;
}
function saveState() {
  const f = stateFile(), tmp = f + '.tmp';
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(stateCache, null, 1));
  fs.renameSync(tmp, f);
}

/* ---------- secrets (safeStorage) ---------- */
function secretsFile() { return path.join(app.getPath('userData'), 'ember-secrets.json'); }
function readSecrets() { try { return JSON.parse(fs.readFileSync(secretsFile(), 'utf8')); } catch { return {}; } }
function secretGet(key) {
  const all = readSecrets(); if (!all[key]) return null;
  try { return safeStorage.decryptString(Buffer.from(all[key], 'base64')); } catch { return null; }
}
function secretSet(key, value) {
  const all = readSecrets();
  if (value == null || value === '') delete all[key];
  else all[key] = safeStorage.encryptString(String(value)).toString('base64');
  const f = secretsFile(), tmp = f + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(all)); fs.renameSync(tmp, f);
}

/* ---------- service client (JSON lines over the named pipe) ---------- */
/* Tri-state service truthfulness (audit H-1/M-4). Three distinguishable
 * states, never collapsed into one another:
 *   'running' — pipe connected AND hello answered (svc:status additionally
 *               requires service.status to answer; see the IPC handler).
 *   'error'   — the pipe connected but something is wrong: hello failed, or
 *               a live service.status call threw / timed out. `error`
 *               carries the actual message.
 *   'absent'  — the pipe connection itself is refused / unreachable; the
 *               service is not there. `error` carries the connect error.
 * Socket-connect and hello success are tracked SEPARATELY (pipeUp vs
 * helloOk): a connected socket alone never proves a running service. */
/* Per-method IPC timeouts (audit W1): the default stays 30 s, but
 * methods whose service-side work legitimately runs longer get a
 * budget that covers it — lantern.call wraps daemon calls the
 * service allows 70 s, and wg.start polls the SCM through slow
 * sc.exe runs. A shell timeout shorter than the service's own
 * duration desyncs state: the shell marks Failed while the service
 * completes the start. */
/* ur.connect is ASYNCHRONOUS in the service (FIX-ADV B1: it
 * validates, kicks the attempt off, and returns the state word
 * at once; progress is followed via ur.status), so its 15 s is
 * a formality over a fast call. ur.countries can legitimately
 * take ~60 s (30 s JWT exchange + the SDK's location lookup),
 * so it gets a budget that covers the service's own. ur.status
 * and ur.disconnect are fast state reads/writes — the default
 * covers them. */
const CALL_TIMEOUTS_MS = { 'lantern.call': 90000, 'wg.start': 75000,
  'ur.connect': 15000, 'ur.countries': 90000 };
const DEFAULT_CALL_TIMEOUT_MS = 30000;

class ServiceClient {
  constructor() {
    this.sock = null; this.buf = ''; this.nextId = 1;
    this.pending = new Map(); this.retry = null;
    this.pipeUp = false;      // socket connected to the pipe
    this.helloOk = false;     // hello answered on this socket
    this.helloSettled = false; // first hello outcome (ok OR fail) seen — latches
    this.lastError = null;    // last connect / hello error message
    this.listeners = [];
  }
  onEvent(fn) { this.listeners.push(fn); }
  emitEvent(ev) { this.listeners.forEach(fn => { try { fn(ev); } catch {} }); }
  emitState() { this.emitEvent({ event: 'service.state', data: this.snapshot() }); }
  /* Current tri-state snapshot (no live call). `error` is present on
   * 'error' and 'absent', absent on 'running'.
   * Pre-hello phase (audit W12): until the FIRST hello settles, the
   * snapshot is the sentinel {state:'error', error:'connecting'} —
   * "not yet connected" must never be reported as 'absent' ("not
   * installed"): at every launch there is a window where the socket
   * is still connecting and hello has not answered. The first
   * socket error/close also settles the phase (a refused pipe IS
   * the first outcome). After that, normal tri-state rules apply. */
  snapshot() {
    if (!this.helloSettled) return { state: 'error', error: 'connecting' };
    if (this.sock && this.pipeUp && this.helloOk) return { state: 'running' };
    if (this.sock && this.pipeUp) {
      return { state: 'error', error: this.lastError || 'Ember service hello failed' };
    }
    return { state: 'absent', error: this.lastError || 'Ember service unreachable' };
  }
  connect() {
    if (this.sock) return;
    // Dev/test override (never set in production): EMBER_SERVICE_ADDR=
    // host:port dials the service's loopback console listener instead of
    // the named pipe — this is how the contract suite and the end-to-end
    // verification drive the real shell against the real service.
    const devAddr = process.env.EMBER_SERVICE_ADDR;
    let s;
    if (devAddr) {
      const i = devAddr.lastIndexOf(':');
      s = net.connect({ host: devAddr.slice(0, i), port: Number(devAddr.slice(i + 1)) });
    } else {
      s = net.connect(PIPE);
    }
    this.sock = s;
    let sockError = null;
    s.setEncoding('utf8');
    s.on('connect', async () => {
      this.pipeUp = true;
      try {
        await this.call('hello', { appRoot: appRoot() });
        this.helloOk = true; this.lastError = null;
      } catch (e) {
        this.helloOk = false;
        this.lastError = String(e.message || e);
      }
      this.helloSettled = true; // first hello outcome, ok or fail (W12)
      if (this.sock === s) this.emitState();
    });
    s.on('data', d => {
      this.buf += d;
      let i;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i).trim(); this.buf = this.buf.slice(i + 1);
        if (!line) continue;
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        if (msg.event) { this.emitEvent(msg); continue; }
        const p = this.pending.get(msg.id);
        if (p) { this.pending.delete(msg.id); msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error || 'service error')); }
      }
    });
    const down = () => {
      if (this.sock && this.sock !== s) return; // stale socket (reconnectNow already replaced it)
      this.helloSettled = true; // a refused/closed pipe settles the pre-hello phase (W12)
      const wasUp = this.pipeUp || this.helloOk;
      this.pipeUp = false; this.helloOk = false;
      if (sockError) this.lastError = String(sockError.message || sockError);
      else if (!wasUp && !this.lastError) this.lastError = 'Ember service unreachable';
      else if (wasUp) this.lastError = 'Ember service connection closed';
      for (const p of this.pending.values()) p.reject(new Error('Ember service unreachable'));
      this.pending.clear();
      if (this.sock === s) this.sock = null;
      this.emitState(); // pipe is gone → 'absent' with the connect/close error
      if (!this.retry) this.retry = setTimeout(() => { this.retry = null; this.connect(); }, 4000);
    };
    s.on('error', e => { sockError = e; down(); });
    s.on('close', down);
  }
  /* Kick an immediate reconnect (e.g. right after a successful install).
   * No-op when the service is already proven running. */
  reconnectNow() {
    if (this.retry) { clearTimeout(this.retry); this.retry = null; }
    if (this.sock && this.helloOk) return;
    if (this.sock) {
      const s = this.sock; this.sock = null;
      this.pipeUp = false; this.helloOk = false;
      try { s.destroy(); } catch {}
    }
    this.connect();
  }
  call(method, params) {
    if (!this.sock || !this.pipeUp) return Promise.reject(new Error('Ember service unreachable'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ v: 1, id, method, params: params || {} }) + '\n');
      const timeoutMs = CALL_TIMEOUTS_MS[method] || DEFAULT_CALL_TIMEOUT_MS;
      setTimeout(() => { if (this.pending.delete(id)) reject(new Error('service call timed out: ' + method)); }, timeoutMs);
    });
  }
}
const service = new ServiceClient();

/* ---------- updater (pinned guard from build 2040) ---------- */
function checkUpdates() {
  return new Promise((resolve) => {
    const req = https.get('https://api.github.com/repos/Mojdee12/ralysnd-ember/releases/latest',
      { headers: { 'User-Agent': 'RalysndEmber/2.2.0', Accept: 'application/vnd.github+json' } }, res => {
        let body = ''; res.on('data', c => body += c);
        res.on('end', () => {
          try {
            const rel = JSON.parse(body);
            const asset = (rel.assets || []).find(a => a.name.includes('Setup') && a.name.endsWith('.exe'));
            if (!asset) return resolve({ available: false, reason: 'Latest release carries no Windows installer.' });
            const latest = String(rel.tag_name || '').replace(/^v/, '');
            resolve({ available: latest !== app.getVersion(), version: rel.tag_name,
                      url: asset.browser_download_url, name: asset.name });
          } catch (e) { resolve({ available: false, reason: 'Update check failed: ' + e.message }); }
        });
      });
    req.on('error', e => resolve({ available: false, reason: 'Update check failed: ' + e.message }));
    req.setTimeout(15000, () => { req.destroy(); resolve({ available: false, reason: 'Update check timed out.' }); });
  });
}

/* ---------- settings side effects (audit H-4) ----------
 * Only the side effects that genuinely exist in the main process are
 * applied; every other canonical settings key is data for the renderer /
 * controllers and gets NO fake behaviour here.
 *   settings.startOnBoot → app.setLoginItemSettings({openAtLogin})
 *   settings.closeToTray → honoured by the window 'close' handler below. */
function applySettingsSideEffects() {
  const st = (loadState().settings) || {};
  try { app.setLoginItemSettings({ openAtLogin: !!st.startOnBoot }); } catch {}
  applyShortcut(); // settings.globalShortcut (UI-S-B2 task 9)
}

/* ---------- window / tray ---------- */
let win = null, tray = null, protectionWord = 'Not protected', quitting = false;
function trayIcon() {
  const candidates = [
    path.join(__dirname, '..', 'app', 'assets', 'logo.png'),   // dev tree
    path.join(appRoot(), 'app', 'assets', 'logo.png'),          // beside the app, if shipped
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) {
        const img = nativeImage.createFromPath(c);
        if (!img.isEmpty()) return img.resize({ width: 16, height: 16 });
      }
    } catch {}
  }
  return nativeImage.createEmpty();
}
function createWindow() {
  /* Clamp to the primary display's work area (audit B-4): never create a
   * window larger than the usable screen, and never let the minimum size
   * exceed it either. Centred in the work area. The renderer's fitStage
   * scales to the window, so a clamped window fits the screen. */
  const wa = screen.getPrimaryDisplay().workAreaSize;
  const width = Math.min(1440, wa.width);
  const height = Math.min(900, wa.height);
  win = new BrowserWindow({
    width, height, useContentSize: true,
    minWidth: Math.min(1100, width), minHeight: Math.min(700, height),
    // Frameless (owner requirement C — unified custom top bar): the
    // renderer draws the titlebar; window control goes through the
    // win:* IPC handlers below.
    frame: false,
    backgroundColor: '#050607', title: 'Ralysnd Ember', autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  win.center();
  /* Maximized-state changes for the renderer's maximize/restore
   * glyph swap: 'win:maximized' carries the new boolean state. */
  const sendMaximized = () => {
    if (win && !win.isDestroyed()) win.webContents.send('win:maximized', win.isMaximized());
  };
  win.on('maximize', sendMaximized);
  win.on('unmaximize', sendMaximized);
  // FIX-ADV L5: the renderer's maximize glyph is written ONLY
  // from this event push (single writer) — so push the initial
  // state once the renderer is up, or a window that starts
  // maximized would show the wrong glyph until the first toggle.
  win.webContents.once('did-finish-load', sendMaximized);
  /* settings.closeToTray: hide to the tray instead of quitting — only
   * when a tray actually exists to bring the window back from. */
  win.on('close', (e) => {
    const st = (loadState().settings) || {};
    if (!quitting && tray && st.closeToTray) { e.preventDefault(); win.hide(); }
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'),
    { hash: SHOOT ? '/home' : '' });
  win.on('closed', () => { win = null; });
}
function refreshTray() {
  if (!tray) return;
  tray.setToolTip(`Ralysnd Ember — ${protectionWord}`);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: `Ralysnd Ember — ${protectionWord}`, enabled: false },
    { type: 'separator' },
    { label: 'Show', click: () => { if (!win) createWindow(); win.show(); win.focus(); } },
    { label: 'Quit', click: () => { quitting = true; app.quit(); } },
  ]));
}

/* ---------- IPC ---------- */
ipcMain.handle('svc:call', (_e, method, params) => service.call(method, params));
/* Tri-state status (audit H-1/M-4) — exact return shapes:
 *   { state: 'running', detail: <service.status payload> }
 *   { state: 'error',   error: <actual message> }   pipe up / status call failed
 *   { state: 'absent',  error: <connect error> }    pipe unreachable
 *   { state: 'error',   error: 'connecting' }       pre-hello sentinel (W12)
 * A failed or timed-out service.status call is 'error', NEVER 'absent'. */
ipcMain.handle('svc:status', async () => {
  const snap = service.snapshot();
  if (snap.state !== 'running') return snap;
  try { return { state: 'running', detail: await service.call('service.status', {}) }; }
  catch (e) { return { state: 'error', error: String(e.message || e) }; }
});
/* Install (audit H-3): run the service's `install` verb NOT detached —
 * capture stdout/stderr, await the exit (120 s timeout), and report the
 * verb's real outcome. ok:true means the verb exited 0, never "spawned".
 * On success the ServiceClient reconnect is kicked immediately. */
ipcMain.handle('svc:install', () => new Promise((resolve) => {
  const exe = enginePath('core', 'ember-service.exe');
  if (!fs.existsSync(exe)) return resolve({ ok: false, code: null, message: 'ember-service.exe not found in the core folder.' });
  let child;
  try { child = spawn(exe, ['install'], { stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (e) { return resolve({ ok: false, code: null, message: 'Failed to launch the service installer: ' + String(e.message || e) }); }
  let out = '', err = '', done = false;
  const finish = (r) => { if (done) return; done = true; clearTimeout(timer); resolve(r); };
  const timer = setTimeout(() => {
    try { child.kill(); } catch {}
    finish({ ok: false, code: null, message: 'Service install timed out after 120 s.' });
  }, 120000);
  if (child.stdout) child.stdout.on('data', d => { out += d; });
  if (child.stderr) child.stderr.on('data', d => { err += d; });
  child.on('error', e => finish({ ok: false, code: null, message: 'Failed to launch the service installer: ' + String(e.message || e) }));
  child.on('close', code => {
    const message = err.trim() || out.trim() ||
      (code === 0 ? 'Ember service installed.' : `Service install exited with code ${code}.`);
    if (code === 0) service.reconnectNow();
    finish({ ok: code === 0, code, message });
  });
}));
/* TCP reachability probe for the renderer's Servers test buttons and
 * SOCKS readiness checks: {host, port, timeoutMs} →
 * {ok:true, ms} | {ok:false, error}. */
ipcMain.handle('net:tcpPing', (_e, opts) => new Promise((resolve) => {
  const host = String((opts && opts.host) || '');
  const port = Number(opts && opts.port);
  const timeoutMs = Math.min(Math.max(Number(opts && opts.timeoutMs) || 5000, 100), 30000);
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) {
    return resolve({ ok: false, error: 'net:tcpPing needs a valid host and port.' });
  }
  const started = Date.now();
  let sock, done = false;
  const finish = (r) => { if (done) return; done = true; try { sock.destroy(); } catch {} resolve(r); };
  try { sock = net.connect({ host, port }); }
  catch (e) { return resolve({ ok: false, error: String(e.message || e) }); }
  sock.setTimeout(timeoutMs, () => finish({ ok: false, error: `TCP connect to ${host}:${port} timed out after ${timeoutMs} ms.` }));
  sock.once('connect', () => finish({ ok: true, ms: Date.now() - started }));
  sock.once('error', e => finish({ ok: false, error: String(e.message || e) }));
}));
/* Subscription fetch for the renderer (2042): renderer fetch() is bound
 * by CORS, which subscription hosts do not grant; the main process is
 * not. GET only, bounded size and time. {url} → {ok:true, text} |
 * {ok:false, error}. */
ipcMain.handle('net:fetchText', async (_e, opts) => {
  const url = String((opts && opts.url) || '');
  if (!/^https?:\/\//i.test(url)) return { ok: false, error: 'net:fetchText needs an http(s) URL.' };
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 20000);
    // UI-S-B2: optional caller headers (e.g. x-hwid for subscription
    // panels, mirroring Android sub_fetcher.dart). FIX-ADV L4:
    // caller headers are ALLOWLISTED — only 'x-hwid'
    // (case-insensitive) passes; everything else is dropped, so
    // the fixed User-Agent below can never be overridden and no
    // renderer code can attach arbitrary headers to a fetch.
    const headers = { 'user-agent': 'RalysndEmber/2.2' };
    if (opts && opts.headers && typeof opts.headers === 'object') {
      for (const [k, v] of Object.entries(opts.headers)) {
        if (String(k).toLowerCase() !== 'x-hwid') continue;
        if (v != null && String(v) !== '') headers['x-hwid'] = String(v);
      }
    }
    const res = await fetch(url, { signal: ctl.signal, redirect: 'follow', headers });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, error: 'HTTP ' + res.status };
    const text = await res.text();
    if (text.length > 8 * 1024 * 1024) return { ok: false, error: 'Subscription body too large.' };
    return { ok: true, text };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
});
/* ---------- UI-S-B2 loopback + diagnostics IPC ---------- */
/* Mozilla core dashboard API (UI-S-B2 task 1): the running
 * firefox-vpn-core serves http://127.0.0.1:10820 (core/internal/
 * service/dashboard.go). This helper is HARD-CODED to that base —
 * method + path only, no host/port/url input is accepted, so the
 * renderer can never aim it anywhere else. Returns {status, json}
 * (json null when the body is not JSON); a refused connection is
 * {status:0, error} so the UI can say "core not running". */
const MOZILLA_API_BASE = 'http://127.0.0.1:10820';
ipcMain.handle('net:httpLocal', async (_e, opts) => {
  const method = String((opts && opts.method) || 'GET').toUpperCase();
  const p = String((opts && opts.path) || '');
  if (!['GET', 'POST'].includes(method)) return { status: 0, error: 'net:httpLocal allows GET/POST only.' };
  if (!p.startsWith('/api/') || p.includes('://') || p.includes('..')) {
    return { status: 0, error: 'net:httpLocal path must be a core /api/* path.' };
  }
  // FIX-ADV H3: the literal checks above are not a confinement
  // proof — WHATWG URL parsing normalises percent-encoded dot
  // segments (/api/%2e%2e/x arrives as /x). Reject any raw '%'
  // outright, then re-check the PARSED pathname against the
  // /api/ prefix before the URL is ever fetched.
  if (p.includes('%')) {
    return { status: 0, error: 'net:httpLocal path must be a core /api/* path.' };
  }
  let parsedPath = '';
  try { parsedPath = new URL(p, MOZILLA_API_BASE).pathname; } catch { parsedPath = ''; }
  if (!parsedPath.startsWith('/api/')) {
    return { status: 0, error: 'net:httpLocal path must be a core /api/* path.' };
  }
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 30000);
    const res = await fetch(MOZILLA_API_BASE + p, {
      method, signal: ctl.signal, redirect: 'manual',
      headers: opts && opts.body !== undefined ? { 'content-type': 'application/json' } : {},
      body: opts && opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
    clearTimeout(timer);
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch { /* non-JSON body — json stays null */ }
    return { status: res.status, json, text: json === null ? text.slice(0, 500) : undefined };
  } catch (e) { return { status: 0, error: String(e.message || e) }; }
});
/* Speed test through a live SOCKS port (UI-S-B2 task 3a): download
 * the URL through socks5://127.0.0.1:<socksPort> counting bytes +
 * elapsed. FIX-ADV H1: the measurement runs on a THROWAWAY
 * session (a dedicated partition, cache off) whose proxy is set
 * to the test SOCKS — session.defaultSession, which renders the
 * app itself, is NEVER mutated, so there is no capture/restore
 * of its proxy at all (the old code "restored" resolveProxy's
 * per-URL result as if it were the configured rules, freezing
 * one PAC decision as a global static rule) and overlapping
 * tests cannot corrupt anything shared. */
ipcMain.handle('net:speedTest', async (_e, opts) => {
  const port = Number(opts && opts.socksPort);
  const url = String((opts && opts.url) || '');
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { ok: false, error: 'net:speedTest needs a valid socksPort.' };
  if (!/^https:\/\//i.test(url)) return { ok: false, error: 'net:speedTest needs an https URL.' };
  const ses = session.fromPartition('ember-speedtest', { cache: false });
  const started = Date.now();
  try {
    await ses.setProxy({ proxyRules: 'socks5://127.0.0.1:' + port });
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 60000);
    const res = await ses.fetch(url, { signal: ctl.signal });
    if (!res.ok) { clearTimeout(timer); return { ok: false, error: 'Speed test HTTP ' + res.status }; }
    let bytes = 0;
    const reader = res.body.getReader();
    for (;;) { const { done, value } = await reader.read(); if (done) break; bytes += value.length; }
    clearTimeout(timer);
    const ms = Date.now() - started;
    return { ok: true, bytes, ms, mbps: ms > 0 ? (bytes * 8 / (ms / 1000) / 1e6) : 0 };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
});
/* Through-proxy DNS probe (UI-S-B2 task 3c): manual SOCKS5 TCP
 * connect through the live proxy to <dnsServer>:53, then a minimal
 * DNS-over-TCP A query for example.com. Resolves {ok:true, ms}
 * with ms = time to the first response byte, after validating the
 * response transaction id; anything else is an honest error. */
ipcMain.handle('net:dnsProbe', (_e, opts) => new Promise((resolve) => {
  const socksHost = String((opts && opts.socksHost) || '127.0.0.1');
  const socksPort = Number(opts && opts.socksPort);
  const dnsServer = String((opts && opts.dnsServer) || '');
  if (!Number.isInteger(socksPort) || socksPort < 1 || socksPort > 65535 || !/^\d{1,3}(\.\d{1,3}){3}$/.test(dnsServer)) {
    return resolve({ ok: false, error: 'net:dnsProbe needs a SOCKS port and an IPv4 DNS server.' });
  }
  const id = Math.floor(Math.random() * 65536);
  const qname = Buffer.concat([Buffer.from([7]), Buffer.from('example'), Buffer.from([3]), Buffer.from('com'), Buffer.from([0])]);
  const query = Buffer.alloc(12 + qname.length + 4);
  query.writeUInt16BE(id, 0); query.writeUInt16BE(0x0100, 2); query.writeUInt16BE(1, 4);
  qname.copy(query, 12); query.writeUInt16BE(1, 12 + qname.length); query.writeUInt16BE(1, 14 + qname.length);
  const framed = Buffer.alloc(2 + query.length);
  framed.writeUInt16BE(query.length, 0); query.copy(framed, 2);
  const started = Date.now();
  let sock, stage = 0, buf = Buffer.alloc(0), done = false;
  const finish = r => { if (done) return; done = true; try { sock.destroy(); } catch {} resolve(r); };
  try { sock = net.connect({ host: socksHost, port: socksPort }); }
  catch (e) { return resolve({ ok: false, error: String(e.message || e) }); }
  sock.setTimeout(10000, () => finish({ ok: false, error: 'DNS probe timed out.' }));
  sock.once('error', e => finish({ ok: false, error: String(e.message || e) }));
  sock.once('connect', () => sock.write(Buffer.from([5, 1, 0])));
  sock.on('data', d => {
    buf = Buffer.concat([buf, d]);
    if (stage === 0) {
      if (buf.length < 2) return;
      if (buf[0] !== 5 || buf[1] !== 0) return finish({ ok: false, error: 'SOCKS proxy refused no-auth.' });
      buf = buf.slice(2); stage = 1;
      const ip = dnsServer.split('.').map(Number);
      sock.write(Buffer.concat([Buffer.from([5, 1, 0, 1]), Buffer.from(ip), Buffer.from([0, 53])]));
    }
    if (stage === 1) {
      if (buf.length < 10) return;
      if (buf[1] !== 0) return finish({ ok: false, error: 'SOCKS connect to the DNS server failed (reply ' + buf[1] + ').' });
      buf = buf.slice(10); stage = 2;
      sock.write(framed);
    }
    if (stage === 2) {
      if (buf.length < 4) return; // 2-byte length + at least the id
      const rid = buf.readUInt16BE(2);
      if (rid !== id) return finish({ ok: false, error: 'DNS response id mismatch.' });
      return finish({ ok: true, ms: Date.now() - started });
    }
  });
}));
/* Problem-report files (UI-S-B2 task 6): saveTextFile asks where;
 * saveDailyReport writes userData/reports/<date>.txt silently and
 * returns the path. Content is renderer-built and secret-free by
 * construction (see app.js buildProblemReport). */
ipcMain.handle('ember:saveTextFile', async (_e, opts) => {
  const name = String((opts && opts.suggestedName) || 'ember-report.txt').replace(/[\\/:*?"<>|]/g, '_');
  const r = await dialog.showSaveDialog(win, { title: 'Save problem report', defaultPath: name,
    filters: [{ name: 'Text', extensions: ['txt'] }] });
  if (r.canceled || !r.filePath) return { ok: false, cancelled: true };
  try { fs.writeFileSync(r.filePath, String((opts && opts.text) || '')); return { ok: true, path: r.filePath }; }
  catch (e) { return { ok: false, error: String(e.message || e) }; }
});
ipcMain.handle('ember:saveDailyReport', (_e, opts) => {
  const date = String((opts && opts.date) || '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return { ok: false, error: 'ember:saveDailyReport needs a YYYY-MM-DD date.' };
  try {
    const dir = path.join(app.getPath('userData'), 'reports');
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, date + '.txt');
    fs.writeFileSync(f, String((opts && opts.text) || ''));
    return { ok: true, path: f };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
});
/* Global shortcut (UI-S-B2 task 9, the QS-tile substitute):
 * settings.globalShortcut (DEFAULT OFF) registers Ctrl+Alt+E,
 * which asks the renderer to toggle-connect the selected engine.
 * Applied from applySettingsSideEffects (every store:set) and from
 * the explicit ember:applyShortcut IPC; unregistered on quit. */
let shortcutRegistered = false;
function applyShortcut() {
  const on = !!((loadState().settings || {}).globalShortcut);
  try {
    if (on && !shortcutRegistered) {
      shortcutRegistered = globalShortcut.register('CommandOrControl+Alt+E', () => {
        if (win && !win.isDestroyed()) {
          if (!win.isVisible()) win.show();
          win.webContents.send('app:shortcutToggle');
        }
      });
    } else if (!on && shortcutRegistered) {
      globalShortcut.unregister('CommandOrControl+Alt+E');
      shortcutRegistered = false;
    }
  } catch { /* headless CI — the shortcut is optional */ }
}
ipcMain.handle('ember:applyShortcut', (_e, opts) => {
  const s = loadState();
  s.settings = Object.assign({}, s.settings, { globalShortcut: !!(opts && opts.on) });
  saveState(); applyShortcut();
  return shortcutRegistered;
});
ipcMain.handle('store:get', (_e, key) => { const s = loadState(); return key ? s[key] : s; });
ipcMain.handle('store:set', (_e, key, value) => {
  const s = loadState(); s[key] = value; saveState();
  applySettingsSideEffects();   // startOnBoot / closeToTray take effect on save
  return true;
});
ipcMain.handle('secret:get', (_e, key) => secretGet(key));
ipcMain.handle('secret:set', (_e, key, value) => { secretSet(key, value); return true; });
ipcMain.handle('secret:has', (_e, key) => secretGet(key) != null);
ipcMain.handle('updater:check', () => checkUpdates());
/* ---------- window controls (owner requirement C) ----------
 * The frameless window's minimize / maximize / close, driven by the
 * renderer's custom top bar. 'win:maximizeToggle' still returns
 * the NEW isMaximized state for any caller that wants it, but the
 * renderer's maximize GLYPH is written ONLY from the
 * 'win:maximized' event push (FIX-ADV L5, single writer — an
 * invoke result landing after the event could otherwise paint a
 * stale glyph). NOTE: 'win:close' goes
 * through the normal window 'close' path, so settings.closeToTray
 * still hides to the tray instead of quitting when enabled. */
ipcMain.handle('win:minimize', () => { if (win && !win.isDestroyed()) win.minimize(); return true; });
ipcMain.handle('win:maximizeToggle', () => {
  if (!win || win.isDestroyed()) return false;
  if (win.isMaximized()) win.unmaximize(); else win.maximize();
  return win.isMaximized();
});
ipcMain.handle('win:close', () => { if (win && !win.isDestroyed()) win.close(); return true; });
ipcMain.handle('win:isMaximized', () => !!(win && !win.isDestroyed() && win.isMaximized()));
/* ---------- backup / restore (2042 Phase 3) ----------
 * Export writes the FULL store JSON (the same document the store
 * persists) to a user-chosen file. Import reads + parses a chosen
 * file and returns the parsed object — validation and application
 * are the renderer's job (it owns the store shape). App lock needs
 * NO main-process support: the PIN hash is renderer data, storable
 * through the existing store:set / secret:set bridges. */
ipcMain.handle('ember:backupExport', async () => {
  const r = await dialog.showSaveDialog(win, {
    title: 'Export Ember backup', defaultPath: 'ember-backup.json',
    filters: [{ name: 'Ember backup', extensions: ['json'] }],
  });
  if (r.canceled || !r.filePath) return { ok: false, cancelled: true };
  try {
    fs.writeFileSync(r.filePath, JSON.stringify(loadState(), null, 1));
    return { ok: true, path: r.filePath };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
});
ipcMain.handle('ember:backupImport', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Import Ember backup', properties: ['openFile'],
    filters: [{ name: 'Ember backup', extensions: ['json'] }],
  });
  if (r.canceled || !r.filePaths || !r.filePaths[0]) return { ok: false, cancelled: true };
  try {
    const data = JSON.parse(fs.readFileSync(r.filePaths[0], 'utf8'));
    return { ok: true, data };
  } catch (e) { return { ok: false, error: 'Backup file is not valid JSON: ' + String(e.message || e) }; }
});
/* ---------- RegionHop defaults (2042 Phase 3) ----------
 * The real panel defaults reach a packaged build ONLY as
 * resources/regionhop-defaults.json, converted from the CI secret by
 * scripts/build-windows.ps1 (see electron/tools/
 * extract-regionhop-defaults.mjs). Returns the parsed object, or
 * null when no defaults file exists in this build — the renderer
 * (RegionHopController) reports that honestly. Values are never
 * logged here. */
ipcMain.handle('ember:regionhopDefaults', () => {
  const candidates = [
    path.join(appRoot(), 'resources', 'regionhop-defaults.json'),
    process.resourcesPath ? path.join(process.resourcesPath, 'regionhop-defaults.json') : null,
    path.join(appRoot(), 'regionhop-defaults.json'),
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      const d = JSON.parse(fs.readFileSync(c, 'utf8'));
      if (d && typeof d.panelUrl === 'string') return d;
    } catch { /* try the next candidate */ }
  }
  return null;
});
/* Engine config delivery (repair 2042, SINGBOX): sing-box reads its
 * config from a file (no stdin mode), so the renderer hands the
 * generated JSON here; it is written under
 * userData/engine-configs/<name> and the ABSOLUTE PATH is returned
 * for the proc's args. Validation is strict: `name` must be a bare
 * filename (no separators, no traversal), `text` a string under a
 * 1 MiB cap. Invalid input throws — the renderer's invoke rejects
 * with the reason, never a silent partial write. */
ipcMain.handle('ember:writeEngineConfig', (_e, opts) => {
  const name = String((opts && opts.name) || '');
  const text = opts && opts.text;
  if (!name || name !== path.basename(name) || name === '.' || name === '..' ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) || name.length > 128) {
    throw new Error('ember:writeEngineConfig needs a bare filename (letters, digits, dot, dash, underscore).');
  }
  if (typeof text !== 'string') throw new Error('ember:writeEngineConfig needs the config text as a string.');
  if (text.length > 1024 * 1024) throw new Error('ember:writeEngineConfig config text exceeds the 1 MiB cap.');
  const dir = path.join(app.getPath('userData'), 'engine-configs');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
  return file;
});
ipcMain.handle('shell:open', (_e, url) => { if (/^https:\/\//.test(url)) return shell.openExternal(url); });
ipcMain.handle('app:meta', () => ({ version: app.getVersion(), shoot: SHOOT, platform: process.platform,
  appRoot: appRoot(), userData: app.getPath('userData'),
  engineDirs: Object.fromEntries(ENGINE_FOLDERS.map(f => [f, engineDir(f)])) }));
ipcMain.on('app:protection', (_e, word) => { protectionWord = String(word || 'Not protected'); refreshTray(); });

/* ---------- lifecycle ---------- */
if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  app.on('second-instance', () => { if (win) { win.show(); win.focus(); } });
  app.on('before-quit', () => { quitting = true; try { globalShortcut.unregisterAll(); } catch {} });
  app.whenReady().then(() => {
    loadState(); applySettingsSideEffects(); service.connect();
    service.onEvent(ev => { if (win && !win.isDestroyed()) win.webContents.send('svc:event', ev); });
    createWindow();
    try {
      tray = new Tray(trayIcon());
      refreshTray();
    } catch { tray = null; /* headless (xvfb CI) — tray is optional */ }
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}
