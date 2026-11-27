'use strict';
/* Ralysnd Ember — Electron main process.
 * Pure client of the Go Windows service (named pipe \\.\pipe\RalysndEmberService.v1,
 * JSON lines, protocol v=1). No engine logic lives here beyond the IPC client,
 * the persistent store, the safeStorage secret vault and the updater guard. */
const { app, BrowserWindow, Tray, Menu, ipcMain, safeStorage, shell, nativeImage } = require('electron');
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
    emberwarpEngine: 'usque',           // 'usque' (primary) | 'aether' (fallback)
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
class ServiceClient {
  constructor() {
    this.sock = null; this.buf = ''; this.nextId = 1;
    this.pending = new Map(); this.connected = false; this.retry = null;
    this.listeners = [];
  }
  onEvent(fn) { this.listeners.push(fn); }
  emitEvent(ev) { this.listeners.forEach(fn => { try { fn(ev); } catch {} }); }
  connect() {
    if (this.sock) return;
    const s = net.connect(PIPE);
    this.sock = s;
    s.setEncoding('utf8');
    s.on('connect', async () => {
      this.connected = true;
      this.emitEvent({ event: 'service.state', data: { state: 'connected' } });
      try { await this.call('hello', { appRoot: appRoot() }); } catch (e) {
        this.emitEvent({ event: 'service.state', data: { state: 'error', error: String(e.message || e) } });
      }
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
      this.connected = false;
      for (const p of this.pending.values()) p.reject(new Error('Ember service unreachable'));
      this.pending.clear();
      if (this.sock === s) this.sock = null;
      this.emitEvent({ event: 'service.state', data: { state: 'unreachable' } });
      if (!this.retry) this.retry = setTimeout(() => { this.retry = null; this.connect(); }, 4000);
    };
    s.on('error', down); s.on('close', down);
  }
  call(method, params) {
    if (!this.sock || !this.connected) return Promise.reject(new Error('Ember service unreachable'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ v: 1, id, method, params: params || {} }) + '\n');
      setTimeout(() => { if (this.pending.delete(id)) reject(new Error('service call timed out: ' + method)); }, 30000);
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

/* ---------- window / tray ---------- */
let win = null, tray = null, protectionWord = 'Not protected';
function createWindow() {
  win = new BrowserWindow({
    width: 1440, height: 900, useContentSize: true, minWidth: 1100, minHeight: 700,
    backgroundColor: '#050607', title: 'Ralysnd Ember', autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true },
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
    { label: 'Quit', click: () => app.quit() },
  ]));
}

/* ---------- IPC ---------- */
ipcMain.handle('svc:call', (_e, method, params) => service.call(method, params));
ipcMain.handle('svc:status', async () => {
  if (!service.connected) return { state: 'unreachable' };
  try { return { state: 'connected', detail: await service.call('service.status', {}) }; }
  catch (e) { return { state: 'unreachable', error: e.message }; }
});
ipcMain.handle('svc:install', () => {
  const exe = enginePath('core', 'ember-service.exe');
  if (!fs.existsSync(exe)) return { ok: false, error: 'ember-service.exe not found in the core folder.' };
  const child = spawn(exe, ['install'], { detached: true, stdio: 'ignore' });
  child.unref();
  return { ok: true };
});
ipcMain.handle('store:get', (_e, key) => { const s = loadState(); return key ? s[key] : s; });
ipcMain.handle('store:set', (_e, key, value) => { const s = loadState(); s[key] = value; saveState(); return true; });
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
  app.whenReady().then(() => {
    loadState(); service.connect();
    service.onEvent(ev => { if (win && !win.isDestroyed()) win.webContents.send('svc:event', ev); });
    createWindow();
    try {
      tray = new Tray(nativeImage.createEmpty());
      refreshTray();
    } catch { tray = null; /* headless (xvfb CI) — tray is optional */ }
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}
