'use strict';
/* Minimal typed bridge — the renderer never touches Node or the pipe directly. */
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('ember', {
  call: (method, params) => ipcRenderer.invoke('svc:call', method, params),
  serviceStatus: () => ipcRenderer.invoke('svc:status'),
  installService: () => ipcRenderer.invoke('svc:install'),
  tcpPing: (host, port, timeoutMs) => ipcRenderer.invoke('net:tcpPing', { host, port, timeoutMs }),
  fetchText: (url, headers) => ipcRenderer.invoke('net:fetchText', { url, headers }),
  /* UI-S-B2 bridges (main.js net:* / ember:* handlers). */
  httpLocal: (method, path, body) => ipcRenderer.invoke('net:httpLocal', { method, path, body }),
  speedTest: (opts) => ipcRenderer.invoke('net:speedTest', opts),
  dnsProbe: (opts) => ipcRenderer.invoke('net:dnsProbe', opts),
  saveTextFile: (suggestedName, text) => ipcRenderer.invoke('ember:saveTextFile', { suggestedName, text }),
  saveDailyReport: (date, text) => ipcRenderer.invoke('ember:saveDailyReport', { date, text }),
  applyShortcut: (on) => ipcRenderer.invoke('ember:applyShortcut', { on }),
  onShortcutToggle: (cb) => { ipcRenderer.on('app:shortcutToggle', () => cb()); },
  /* Electron 45 removed File.path; webUtils is the supported way to
   * learn an imported file's on-disk path (OpenVPN needs configPath). */
  getPathForFile: (file) => { try { return webUtils.getPathForFile(file) || ''; } catch { return ''; } },
  onEvent: (cb) => { ipcRenderer.on('svc:event', (_e, ev) => cb(ev)); },
  store: {
    get: (key) => ipcRenderer.invoke('store:get', key),
    set: (key, value) => ipcRenderer.invoke('store:set', key, value),
  },
  secrets: {
    get: (key) => ipcRenderer.invoke('secret:get', key),
    set: (key, value) => ipcRenderer.invoke('secret:set', key, value),
    has: (key) => ipcRenderer.invoke('secret:has', key),
  },
  updater: { check: () => ipcRenderer.invoke('updater:check') },
  openExternal: (url) => ipcRenderer.invoke('shell:open', url),
  meta: () => ipcRenderer.invoke('app:meta'),
  setProtection: (word) => ipcRenderer.send('app:protection', word),
  /* Window controls (frameless window, main.js win:* handlers). */
  minimize: () => ipcRenderer.invoke('win:minimize'),
  maximizeToggle: () => ipcRenderer.invoke('win:maximizeToggle'),
  closeWindow: () => ipcRenderer.invoke('win:close'),
  isMaximized: () => ipcRenderer.invoke('win:isMaximized'),
  onMaximizedChange: (cb) => { ipcRenderer.on('win:maximized', (_e, maximized) => cb(maximized)); },
  /* Backup / restore + RegionHop defaults (main.js ember:* handlers). */
  backupExport: () => ipcRenderer.invoke('ember:backupExport'),
  backupImport: () => ipcRenderer.invoke('ember:backupImport'),
  regionhopDefaults: () => ipcRenderer.invoke('ember:regionhopDefaults'),
});
