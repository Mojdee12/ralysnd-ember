'use strict';
/* Screenshot harness: `xvfb-run -a npm run shoot`
 * Launches the app in --shoot mode (demo state seeded, service not required),
 * visits every screen at 1440x900 and writes PNGs to
 * ~/workspace/ember-app/windows-parity/fidelity/<screen>.png */
const { app, BrowserWindow, ipcMain, safeStorage } = require('electron');
app.commandLine.appendSwitch('no-sandbox'); // VM/CI runs as root under xvfb
app.disableHardwareAcceleration();
/* Minimal IPC surface for the harness (mirrors main.js semantics; the real
 * app registers the full set in main.js). Store is backed by userData. */
function registerHarnessIpc() {
  const f = () => path.join(app.getPath('userData'), 'ember-state.json');
  ipcMain.handle('app:meta', () => ({ version: '2.2.0', shoot: true, platform: process.platform, appRoot: path.join(__dirname, '..') }));
  ipcMain.handle('store:get', (_e, key) => { let s = {}; try { s = JSON.parse(fs.readFileSync(f(), 'utf8')); } catch {} return key ? s[key] : s; });
  ipcMain.handle('store:set', (_e, key, value) => { let s = {}; try { s = JSON.parse(fs.readFileSync(f(), 'utf8')); } catch {} s[key] = value; fs.mkdirSync(path.dirname(f()), { recursive: true }); fs.writeFileSync(f() + '.tmp', JSON.stringify(s)); fs.renameSync(f() + '.tmp', f()); return true; });
  ipcMain.handle('secret:get', () => null);
  ipcMain.handle('secret:set', () => true);
  ipcMain.handle('secret:has', () => false);
  ipcMain.handle('svc:call', () => Promise.reject(new Error('Ember service unreachable')));
  ipcMain.handle('svc:status', () => ({ state: 'unreachable' }));
  ipcMain.handle('svc:install', () => ({ ok: false, error: 'not in shoot mode' }));
  ipcMain.handle('updater:check', () => ({ available: false, reason: 'not checked in shoot mode' }));
  ipcMain.handle('shell:open', () => true);
  ipcMain.on('app:protection', () => {});
}
const fs = require('fs');
const path = require('path');
process.env.EMBER_SHOOT = '1';
const OUT = path.join(__dirname, '..', '..', 'windows-parity', 'fidelity');
const SCREENS = ['home', 'home-connected', 'v2ray', 'mozilla', 'lantern', 'wireguard',
  'warp', 'emberwarp', 'masque', 'psiphon', 'openvpn', 'urnetwork', 'servers', 'settings', 'account'];
const sleep = ms => new Promise(r => setTimeout(r, ms));
app.whenReady().then(async () => {
  registerHarnessIpc();
  fs.mkdirSync(OUT, { recursive: true });
  const win = new BrowserWindow({ width: 1440, height: 900, useContentSize: true, backgroundColor: '#050607',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  const errors = [];
  win.webContents.on('console-message', (_e, level, msg) => { if (level >= 3) errors.push(msg); });
  await win.loadFile(path.join(__dirname, 'renderer', 'index.html'), { hash: '/home' });
  await sleep(1200);
  for (const s of SCREENS) {
    await win.webContents.executeJavaScript(`location.hash = '#/${s}'`);
    await sleep(650);
    const img = await win.capturePage();
    fs.writeFileSync(path.join(OUT, s + '.png'), img.toPNG());
    console.log('shot', s);
  }
  if (errors.length) console.log('CONSOLE ERRORS:', errors.join(' | '));
  app.quit();
});
