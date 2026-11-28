'use strict';
/* Minimal typed bridge — the renderer never touches Node or the pipe directly. */
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('ember', {
  call: (method, params) => ipcRenderer.invoke('svc:call', method, params),
  serviceStatus: () => ipcRenderer.invoke('svc:status'),
  installService: () => ipcRenderer.invoke('svc:install'),
  tcpPing: (host, port, timeoutMs) => ipcRenderer.invoke('net:tcpPing', { host, port, timeoutMs }),
  fetchText: (url) => ipcRenderer.invoke('net:fetchText', { url }),
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
});
