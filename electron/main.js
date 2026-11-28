'use strict';
/* Ralysnd Ember — Electron main process.
 * Pure client of the Go Windows service (named pipe \\.\pipe\RalysndEmberService.v1,
 * JSON lines, protocol v=1). No engine logic lives here beyond the IPC client,
 * the persistent store, the safeStorage secret vault and the updater guard. */
const { app, BrowserWindow, Tray, Menu, ipcMain, safeStorage, shell, nativeImage, screen } = require('electron');
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
  },
  engineSettings: {},      // per-engine bags, all feature flags default OFF
  urnetworkAccounts: [],   // {id,label} — API keys live ONLY in the secret vault
  lantern: { privateServers: [], selectedServer: null },
  warpProfile: null,       // filled by warp.register via the service
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
const CALL_TIMEOUTS_MS = { 'lantern.call': 90000, 'wg.start': 75000 };
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
    backgroundColor: '#050607', title: 'Ralysnd Ember', autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  win.center();
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
    const res = await fetch(url, { signal: ctl.signal, redirect: 'follow',
      headers: { 'user-agent': 'RalysndEmber/2.2' } });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, error: 'HTTP ' + res.status };
    const text = await res.text();
    if (text.length > 8 * 1024 * 1024) return { ok: false, error: 'Subscription body too large.' };
    return { ok: true, text };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
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
ipcMain.handle('shell:open', (_e, url) => { if (/^https:\/\//.test(url)) return shell.openExternal(url); });
ipcMain.handle('app:meta', () => ({ version: app.getVersion(), shoot: SHOOT, platform: process.platform,
  appRoot: appRoot(), userData: app.getPath('userData'),
  engineDirs: Object.fromEntries(ENGINE_FOLDERS.map(f => [f, engineDir(f)])) }));
ipcMain.on('app:protection', (_e, word) => { protectionWord = String(word || 'Not protected'); refreshTray(); });

/* ---------- lifecycle ---------- */
if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  app.on('second-instance', () => { if (win) { win.show(); win.focus(); } });
  app.on('before-quit', () => { quitting = true; });
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
