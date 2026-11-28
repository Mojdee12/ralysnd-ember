'use strict';
/* Ralysnd Ember — renderer SPA. Screens are the owner's approved HTML renders
 * (templates.json, extracted mechanically from windows-parity/renders);
 * this file wires them: hash routing, the rail, live engine state words,
 * real toggles (persisted under the canonical camelCase settings keys of
 * main.js DEFAULT_STATE — slug keys are abolished), connect bars, the
 * tri-state service bar, profile import + the Servers page, URnetwork
 * accounts and the guarded updater.
 *
 * Repair 2042: every visible control is either wired to a real action,
 * or disabled with a stated reason (.dis + title). No dead controls. */
const { controllers: CTRLS, engineState, wireServiceEvents, isConnectedWord, reconcile } = window.EmberControllers;
const EP = window.EmberProfiles;
const ENGINES = ['v2ray', 'mozilla', 'lantern', 'wireguard', 'warp', 'psiphon', 'openvpn', 'emberwarp', 'masque', 'urnetwork'];
const ENGINE_LABEL = { v2ray: 'V2Ray', mozilla: 'Mozilla', lantern: 'Lantern', wireguard: 'WireGuard', warp: 'WARP', psiphon: 'Psiphon', openvpn: 'OpenVPN', emberwarp: 'EmberWarp', masque: 'MASQUE', urnetwork: 'URnetwork' };
let templates = {}, store = {}, meta = {}, currentScreen = 'home';
let serversFilter = 'all', serversQuery = '';

const DEMO_PROFILES = [
  { id: 'demo-1', name: 'Frankfurt — VLESS', protocol: 'vless', address: 'de.example.net', port: 443, security: 'tls', engine: 'v2ray', group: 'My servers', ping: 84 },
  { id: 'demo-2', name: 'Netherlands — Trojan', protocol: 'trojan', address: 'nl.example.net', port: 443, security: 'tls', engine: 'v2ray', group: 'My servers', ping: 96 },
  { id: 'demo-3', name: 'Plain HTTP proxy', protocol: 'http', address: 'proxy.example.net', port: 8080, security: 'none', engine: 'v2ray', group: 'My servers', ping: 121 },
];

/* Canonical settings (main.js DEFAULT_STATE.settings, camelCase).
 * SETTING_DEFAULTS mirrors main's defaults for keys an older state
 * file may lack; sniffing/fakeDns/routingPreset/domainStrategy are
 * renderer-consumed keys (the Xray config builder reads them) with
 * v2rayNG-matching defaults. */
const SETTING_DEFAULTS = {
  smartRouting: false, killSwitch: false, autoConnect: false,
  byedpiHop: false, dailyProblemReport: false, appLock: false,
  sessionBudget: false, batteryReport: false, leakTestOnConnect: false,
  tunMode: true, systemProxy: false, emberwarpEngine: 'usque',
  remoteDns: 'https://dns.google/dns-query', localDns: '8.8.8.8', socksPort: 10808,
  startOnBoot: false, closeToTray: false,
  sniffing: true, fakeDns: false, routingPreset: 'global', domainStrategy: 'IPIfNonMatch',
};
function settingGet(key) {
  const s = store.settings || {};
  return s[key] !== undefined ? s[key] : SETTING_DEFAULTS[key];
}
async function persistSetting(key, value) {
  store.settings = store.settings || {};
  store.settings[key] = value;
  window.__emberSettings = store.settings;
  await window.ember.store.set('settings', store.settings);
}
async function persistProfiles() { await window.ember.store.set('profiles', store.profiles || []); }

function route() {
  const h = (location.hash || '#/home').replace('#/', '');
  return ['home', 'home-connected', ...ENGINES, 'servers', 'settings', 'account'].includes(h) ? h : 'home';
}
function engineOf(screen) {
  if (ENGINES.includes(screen)) return screen;
  if (screen === 'home' || screen === 'home-connected') return (store.selectedEngine || 'mozilla');
  return null;
}
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function disableWithReason(el, reason) {
  if (!el) return;
  el.classList.add('dis'); el.title = reason; el.style.cursor = 'not-allowed';
  el.onclick = null;
}

/* ---------- profiles ---------- */
function selectedProfile() {
  return (store.profiles || []).find(p => p.id === store.selectedProfileId) || null;
}
function selectedProfileFor(engine) {
  const want = engine === 'urnetwork' ? 'v2ray' : engine;
  const sel = selectedProfile();
  if (sel && sel.engine === want) return sel;
  return (store.profiles || []).find(p => p.engine === want) || null;
}
async function addProfiles(list) {
  store.profiles = [...(store.profiles || []), ...list];
  if (!store.selectedProfileId && list.length) {
    store.selectedProfileId = list[0].id;
    await window.ember.store.set('selectedProfileId', store.selectedProfileId);
  }
  await persistProfiles();
  if (currentScreen === 'servers') renderServersPage();
}

/* ---------- import (B-3) ---------- */
async function importLinksText(text) {
  const lines = String(text || '').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  const added = [], errs = [];
  for (const line of lines) {
    try { added.push(EP.parseLink(line)); } catch (e) { errs.push(e.message); }
  }
  if (!added.length) throw new Error(errs[0] || 'Nothing importable in that text.');
  await addProfiles(added);
  return added.length + ' config(s) imported' + (errs.length ? ' — ' + errs.length + ' line(s) skipped: ' + errs[0] : '');
}
async function importSubscription(url) {
  // Prefer the main-process fetch (no CORS limit on subscription hosts);
  // fall back to renderer fetch if the bridge is unavailable.
  let body;
  if (window.ember.fetchText) {
    const r = await window.ember.fetchText(url);
    if (!r.ok) throw new Error('Subscription fetch failed: ' + r.error);
    body = r.text;
  } else {
    const res = await fetch(url);
    if (!res.ok) throw new Error('Subscription fetch failed: HTTP ' + res.status);
    body = await res.text();
  }
  const { profiles, errors } = EP.parseSubscriptionBody(body);
  if (!profiles.length) throw new Error('No usable configs in that subscription' + (errors.length ? ' (' + errors.length + ' unparseable lines)' : ''));
  profiles.forEach(p => { p.group = url; });
  await addProfiles(profiles);
  store.subscriptions = [...(store.subscriptions || []),
    { id: 'sub-' + Date.now(), name: url, url, updatedAt: Date.now() }];
  await window.ember.store.set('subscriptions', store.subscriptions);
  return profiles.length + ' config(s) imported from the subscription';
}
async function handleImportFiles(files) {
  const added = [], errs = [];
  for (const file of files) {
    try {
      const text = await file.text();
      if (/\.conf$/i.test(file.name)) added.push(EP.parseWireGuardConf(text, file.name));
      else if (/\.ovpn$/i.test(file.name)) {
        const p = EP.parseOvpn(text, file.name);
        // ovpn.start needs the on-disk configPath; the preload's
        // webUtils bridge supplies it (Electron 45 removed File.path).
        p.configPath = (window.ember.getPathForFile && window.ember.getPathForFile(file)) || file.path || '';
        if (!p.configPath) errs.push(file.name + ': imported, but its file path is unavailable — OpenVPN connect needs the path');
        added.push(p);
      } else errs.push(file.name + ': only .conf and .ovpn files are supported');
    } catch (e) { errs.push(file.name + ': ' + e.message); }
  }
  if (added.length) await addProfiles(added);
  if (errs.length) showSvcError(new Error(errs.join(' · ')));
  else if (added.length) showSvcNote(added.length + ' profile(s) imported.');
  if (currentScreen === 'servers') renderServersPage();
}
function pickImportFile() {
  let inp = document.getElementById('ember-file-import');
  if (!inp) {
    inp = document.createElement('input');
    inp.type = 'file'; inp.id = 'ember-file-import'; inp.accept = '.conf,.ovpn';
    inp.multiple = true; inp.style.display = 'none';
    document.body.appendChild(inp);
    inp.onchange = () => { handleImportFiles([...inp.files]).catch(e => showSvcError(e)); inp.value = ''; };
  }
  inp.click();
}

/* ---------- small popup menu (kebab / import) ---------- */
function closeMenu() { const m = document.getElementById('ember-menu'); if (m) m.remove(); }
function showMenu(anchor, items) {
  closeMenu();
  const m = document.createElement('div');
  m.className = 'ember-menu'; m.id = 'ember-menu';
  for (const it of items) {
    const d = document.createElement('div');
    d.className = 'ember-menu-item'; d.textContent = it.label;
    d.onclick = ev => { ev.stopPropagation(); closeMenu(); it.fn(); };
    m.appendChild(d);
  }
  document.body.appendChild(m);
  const r = anchor.getBoundingClientRect();
  m.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 190)) + 'px';
  m.style.top = (r.bottom + 4) + 'px';
  setTimeout(() => document.addEventListener('click', closeMenu, { once: true }), 0);
}

/* ---------- in-app dialogs (2042) ----------
 * Electron does not implement window.prompt/confirm (they silently
 * return null/false), which silently killed the import, rename,
 * delete and update flows that used them. These DOM dialogs are the
 * replacements; both return Promises. */
function emberDialog(message, withInput, initial) {
  return new Promise(resolve => {
    const wrap = document.createElement('div');
    wrap.className = 'ember-dialog-wrap';
    const panel = document.createElement('div');
    panel.className = 'ember-dialog';
    const label = document.createElement('div');
    label.className = 'ember-dialog-msg'; label.textContent = message;
    panel.appendChild(label);
    let input = null;
    if (withInput) {
      input = document.createElement('input');
      input.className = 'ember-dialog-input'; input.type = 'text';
      input.value = initial || '';
      panel.appendChild(input);
    }
    const row = document.createElement('div');
    row.className = 'ember-dialog-row';
    const cancel = document.createElement('button');
    cancel.className = 'ember-dialog-btn'; cancel.textContent = 'Cancel';
    const ok = document.createElement('button');
    ok.className = 'ember-dialog-btn ok'; ok.textContent = 'OK';
    row.appendChild(cancel); row.appendChild(ok);
    panel.appendChild(row);
    wrap.appendChild(panel);
    document.body.appendChild(wrap);
    const done = val => { wrap.remove(); document.removeEventListener('keydown', onKey, true); resolve(val); };
    const onKey = ev => {
      if (ev.key === 'Escape') { ev.stopPropagation(); done(withInput ? null : false); }
      if (ev.key === 'Enter') { ev.stopPropagation(); done(withInput ? input.value : true); }
    };
    document.addEventListener('keydown', onKey, true);
    cancel.onclick = () => done(withInput ? null : false);
    ok.onclick = () => done(withInput ? input.value : true);
    wrap.addEventListener('mousedown', ev => { if (ev.target === wrap) done(withInput ? null : false); });
    if (input) { input.focus(); input.select(); } else ok.focus();
  });
}
const emberPrompt = (message, initial) => emberDialog(message, true, initial);
const emberConfirm = message => emberDialog(message, false);

/* ---------- account page ---------- */
// extractRail pulls the full rail element out of a screen
// template by counting div depth (a regex stops at the first
// nested close and truncates the engines list + foot).
function extractRail(html) {
  const start = html.indexOf('<div class="rail">');
  if (start < 0) return '';
  let depth = 0, i = start;
  while (i < html.length) {
    if (html.startsWith('<div', i)) { depth++; i += 4; continue; }
    if (html.startsWith('</div>', i)) {
      depth--; i += 6;
      if (depth === 0) return html.slice(start, i);
      continue;
    }
    i++;
  }
  return '';
}

function accountHTML() {
  const rail = extractRail(templates.settings).replace('navrow on', 'navrow');
  return `<div class="stage"><div class="map"><img src="../assets/map_backdrop_home.webp" alt=""></div><div class="faint"></div>
  ${rail}
  <div class="content"><div class="phead"><div><div class="micro-o">Ralysnd Ember</div>
  <div class="hero" style="margin-top:10px"><div class="word" style="font-size:40px">Account</div>
  <div class="sub">Version <b id="acct-ver">2.2.0</b> · Electron shell, Go service engine layer</div></div></div></div>
  <div class="rows">
    <div class="krow"><div class="t"><div class="nm">Check for updates</div><div class="ds">Offers a download only when the latest GitHub release carries a Windows Setup .exe.</div></div>
    <div class="val"><button class="chipbtn o" data-action="update">Check</button></div></div>
    <div class="krow"><div class="t"><div class="nm">Update status</div><div class="ds" id="update-word">Not checked yet.</div></div><div class="val"></div></div>
    <div class="krow"><div class="t"><div class="nm">Ember service</div><div class="ds" id="acct-svc">State unknown.</div></div>
    <div class="val"><button class="chipbtn" data-action="install-service">Install the Ember service</button></div></div>
  </div></div></div>`;
}

function render() {
  currentScreen = route();
  let html;
  if (currentScreen === 'account') html = accountHTML();
  else html = templates[currentScreen] || templates.home;
  document.getElementById('app').innerHTML = html;
  if (window.__shootConnected) {
    engineState.set('v2ray', currentScreen === 'home-connected' ? 'Connected' : 'Idle');
  }
  fitStage();
  document.querySelectorAll('.map img').forEach(img => { img.src = '../assets/map_backdrop_home.webp'; });
  wireRail(); wireControls(); refreshRailStates(); refreshConnectBar(); refreshServiceBar();
  const v = document.getElementById('acct-ver'); if (v && meta.version) v.textContent = meta.version;
}

// The stage is a fixed 1440x900 composition; scale it to the
// window (never above 1 by default of the fit — the renders
// are the design size, and smaller windows letterbox).
function fitStage() {
  const stage = document.querySelector('.stage');
  if (!stage) return;
  const s = Math.min(window.innerWidth / 1440, window.innerHeight / 900);
  stage.style.transform = `scale(${s})`;
}
window.addEventListener('resize', fitStage);

function refreshRailStates() {
  document.querySelectorAll('.engrow').forEach(row => {
    const nm = row.querySelector('.nm'); const st = row.querySelector('.st');
    if (!nm || !st) return;
    const eng = Object.keys(ENGINE_LABEL).find(k => ENGINE_LABEL[k] === nm.textContent.trim());
    if (!eng) return;
    let word = engineState.get(eng);
    // Liveness is exact-word equality (audit C4): 'Disconnected'
    // must never light the live dot. Tested BEFORE the ON remap.
    const liveWord = isConnectedWord(word);
    // The renders' rail vocabulary: a connected engine reads ON.
    if (word === 'Connected') word = 'On';
    // The renders' convention: selection + the OPEN word mark
    // the engine whose own page is open (on Home/Servers/
    // Settings no engine row is selected — Home names the
    // current engine in its connect bar instead).
    const onOwnPage = ENGINES.includes(currentScreen) && engineOf(currentScreen) === eng;
    if ((word === 'Idle' || word === 'IDLE') && onOwnPage) word = 'Open';
    st.textContent = word; st.classList.toggle('live', liveWord);
    row.classList.toggle('sel', onOwnPage);
  });
  const foot = document.querySelector('.rail .foot .micro');
  const sdot = document.querySelector('.rail .foot .sdot');
  const live = engineState.anyLive();
  if (foot) foot.textContent = live ? 'Protected' : 'Not protected';
  if (sdot) sdot.classList.toggle('green', live);
  window.ember.setProtection(live ? 'Protected' : 'Not protected');
}

/* The connect bar mirrors the current engine's state word; the pill
 * flips between CONNECT and DISCONNECT. */
function refreshConnectBar() {
  const eng = engineOf(currentScreen);
  if (!eng) return;
  const word = engineState.get(eng);
  // Exact word only (audit C4): 'Disconnected' contains 'connected'
  // and must keep the pill on CONNECT, never flip it to DISCONNECT.
  const connected = isConnectedWord(word);
  document.querySelectorAll('.bar .staterow .word').forEach(w => {
    w.textContent = word === 'Idle' ? 'Not connected' : word;
  });
  document.querySelectorAll('.pill').forEach(p => {
    const w = p.querySelector('.word');
    if (w) w.textContent = connected ? 'DISCONNECT' : 'CONNECT';
    p.classList.toggle('disc', connected);
  });
}

function wireRail() {
  document.querySelectorAll('.navrow').forEach(row => {
    const nm = (row.querySelector('.nm') || {}).textContent || '';
    row.style.cursor = 'pointer';
    row.onclick = () => { location.hash = '#/' + nm.trim().toLowerCase(); };
  });
  document.querySelectorAll('.engrow').forEach(row => {
    const nm = (row.querySelector('.nm') || {}).textContent || '';
    const eng = Object.keys(ENGINE_LABEL).find(k => ENGINE_LABEL[k] === nm.trim());
    if (!eng) return;
    row.style.cursor = 'pointer';
    row.onclick = async () => {
      await window.ember.store.set('selectedEngine', eng); store.selectedEngine = eng;
      location.hash = eng === engineOf('home') && currentScreen === 'home' ? '#/home' : '#/' + eng;
      if (currentScreen !== 'home') location.hash = '#/' + eng; else render();
    };
  });
  const acct = document.querySelector('.rail .foot .acct');
  if (acct) { acct.style.cursor = 'pointer'; acct.onclick = () => { location.hash = '#/account'; }; }
  const em = [...document.querySelectorAll('.emergency .act')][0];
  if (em) { em.style.cursor = 'pointer'; em.onclick = () => toggleConnect(engineOf(currentScreen)); }
}

/* ---------- toggles: canonical keys only ---------- */
/* Returns {key} for a bound toggle, {disabled: reason} for an honest
 * dead-end, or null when the row is handled elsewhere. */
function toggleBinding(label) {
  const l = label.toLowerCase();
  if (currentScreen === 'lantern' && /smart routing/.test(l)) {
    return { disabled: 'Smart routing is not in the service Lantern API allow-list yet.' };
  }
  if (currentScreen === 'urnetwork' && /providing/.test(l)) {
    return { disabled: 'Providing is hard-pinned OFF — this device never becomes an exit for strangers.', forceOff: true };
  }
  if (/start on boot/.test(l)) return { key: 'startOnBoot' };
  if (/close to tray/.test(l)) return { key: 'closeToTray' };
  // Kill switch + Smart routing have NO consumer anywhere in the
  // Windows shell or service (audit W11): honest disabled-with-reason
  // rows, not live write-only toggles. (The Lantern page's smart
  // routing row is handled above with its own allow-list reason.)
  if (/kill switch/.test(l)) return { disabled: 'Kill switch is not wired on Windows yet — nothing in the shell or service consumes it.' };
  if (/smart routing/.test(l)) return { disabled: 'Smart routing is not wired on Windows yet — nothing in the shell or service consumes it.' };
  if (/daily problem report/.test(l)) return { key: 'dailyProblemReport' };
  if (/fakedns/.test(l)) return { key: 'fakeDns' };
  if (/sniffing/.test(l)) return { key: 'sniffing' };
  if (/connected but blocked/.test(l)) return { disabled: 'Connected-but-blocked detection is not implemented on Windows yet.' };
  if (/share on lan/.test(l)) return { disabled: 'LAN sharing is not implemented on Windows yet.' };
  return { disabled: 'No behaviour is bound to this switch in this build.' };
}
function wireToggles() {
  document.querySelectorAll('#app .tgl').forEach(tgl => {
    const row = tgl.closest('.krow,.srow,.growhead');
    const label = row ? ((row.querySelector('.nm,.t') || {}).textContent || '') : '';
    const b = toggleBinding(label.trim());
    if (!b || b.disabled) {
      if (b && b.forceOff) tgl.classList.remove('on');
      disableWithReason(tgl, b ? b.disabled : 'No behaviour is bound to this switch in this build.');
      return;
    }
    tgl.classList.toggle('on', !!settingGet(b.key));
    tgl.style.cursor = 'pointer';
    tgl.onclick = async () => {
      const on = !tgl.classList.contains('on');
      tgl.classList.toggle('on', on);
      await persistSetting(b.key, on);
    };
  });
}

/* ---------- chip buttons on engine pages ---------- */
async function pingProfileInto(p, el) {
  if (!p) { showSvcError(new Error('No profile selected to ping.')); return; }
  const old = el.textContent;
  el.textContent = 'Pinging…';
  const r = await window.ember.tcpPing(p.address, p.port, 3000).catch(e => ({ ok: false, error: String(e.message || e) }));
  el.textContent = r.ok ? 'Ping · ' + r.ms + ' ms' : 'Ping · failed';
  if (r.ok) { p.ping = r.ms; await persistProfiles(); }
  setTimeout(() => { el.textContent = old; }, 4000);
}
async function refreshWarpDisplay() {
  const p = CTRLS.warp.profile || store.warpProfile;
  if (!p) return;
  document.querySelectorAll('#app .krow').forEach(row => {
    const nm = (row.querySelector('.nm') || {}).textContent || '';
    const val = row.querySelector('.val');
    if (val && /endpoint/i.test(nm)) val.innerHTML = esc(p.endpoint || '—') + ' <span class="chev">›</span>';
  });
}
const WARP_ENDPOINTS = ['engage.cloudflareclient.com:2408', '162.159.192.1:2408', '162.159.193.1:2408'];
async function cycleWarpEndpoint() {
  if (!CTRLS.warp.profile && !store.warpProfile) await CTRLS.warp.register(false);
  const p = CTRLS.warp.profile || store.warpProfile;
  if (!p) throw new Error('No WARP profile yet — register first.');
  const list = [...new Set([p.endpoint, ...WARP_ENDPOINTS].filter(Boolean))];
  const next = list[(list.indexOf(p.endpoint) + 1) % list.length];
  p.endpoint = next;
  CTRLS.warp.profile = p; store.warpProfile = p;
  await window.ember.store.set('warpProfile', p);
  await refreshWarpDisplay();
  showSvcNote('WARP endpoint set to ' + next + ' — applies on the next connect.');
}
async function cycleLanternServer(valEl) {
  const servers = await CTRLS.lantern.servers();
  const list = Array.isArray(servers) ? servers : (servers && (servers.servers || servers.data)) || [];
  if (!list.length) throw new Error('The Lantern daemon returned no servers.');
  const sel = await CTRLS.lantern.selected().catch(() => null);
  const curId = sel && (sel.id || sel.serverId);
  const idx = list.findIndex(s => (s.id || s.serverId) === curId);
  const next = list[(idx + 1) % list.length];
  await CTRLS.lantern.call('POST', '/server/selected', { id: next.id || next.serverId });
  if (valEl) valEl.innerHTML = esc(next.name || next.id || 'Selected') + ' <span class="chev">›</span>';
}
function wireChipbtns() {
  document.querySelectorAll('#app .chipbtn').forEach(btn => {
    if (btn.dataset.action) return; // update / install-service handled elsewhere
    const label = btn.textContent.trim();
    const go = fn => { btn.style.cursor = 'pointer'; btn.onclick = () => { Promise.resolve().then(fn).catch(e => showSvcError(e)); }; };
    if (currentScreen === 'warp' && /^register$/i.test(label)) {
      go(async () => { await CTRLS.warp.register(true); await refreshWarpDisplay(); showSvcNote('WARP identity registered with Cloudflare.'); });
    } else if (currentScreen === 'warp' && /^endpoint$/i.test(label)) {
      go(cycleWarpEndpoint);
    } else if (currentScreen === 'v2ray' && /open in servers/i.test(label)) {
      go(() => { location.hash = '#/servers'; });
    } else if (currentScreen === 'v2ray' && /^ping$/i.test(label)) {
      go(() => pingProfileInto(selectedProfileFor('v2ray'), btn));
    } else if (currentScreen === 'wireguard' && /import \.conf/i.test(label)) {
      go(() => pickImportFile());
    } else if (currentScreen === 'wireguard' && /all tunnels/i.test(label)) {
      go(() => { location.hash = '#/servers'; });
    } else if (currentScreen === 'openvpn' && /import profile/i.test(label)) {
      go(() => pickImportFile());
    } else if (currentScreen === 'openvpn' && /ovpn:\/\/ link/i.test(label)) {
      go(async () => {
        const text = await emberPrompt('Paste the OpenVPN profile text (.ovpn contents):');
        if (!text) return;
        const p = EP.parseOvpn(text, 'pasted.ovpn');
        p.configPath = '';
        await addProfiles([p]);
        showSvcNote('OpenVPN profile imported — note: connect needs its on-disk file path, which a paste cannot provide in this build.');
      });
    } else if ((currentScreen === 'emberwarp' || currentScreen === 'masque') && /^(emberwarp|masque)$/i.test(label)) {
      go(() => { location.hash = '#/' + label.toLowerCase(); });
    } else if (currentScreen === 'urnetwork' && /best available/i.test(label)) {
      go(() => toggleConnect('urnetwork'));
    } else if (currentScreen === 'mozilla') {
      disableWithReason(btn, 'Mozilla sign-in is not available in the Windows shell yet — the core ships without an account UI here.');
    } else if (currentScreen === 'lantern') {
      disableWithReason(btn, 'Private servers are not in the service Lantern API allow-list yet.');
    } else if (currentScreen === 'psiphon') {
      disableWithReason(btn, 'Psiphon region / server-entry controls are not wired to the core in this build.');
    } else if (currentScreen === 'urnetwork' && /pick country/i.test(label)) {
      disableWithReason(btn, 'Country picking needs the URnetwork source page, which is not part of this build; managed profiles live in Servers.');
    } else {
      disableWithReason(btn, 'No action is bound to this button in this build.');
    }
  });
}

/* ---------- chevron rows (.krow .val) on engine pages ---------- */
function wireKrows() {
  if (currentScreen === 'settings' || currentScreen === 'servers' || currentScreen === 'account') return;
  document.querySelectorAll('#app .krow').forEach(row => {
    const nm = ((row.querySelector('.nm') || {}).textContent || '').trim();
    const val = row.querySelector('.val');
    if (!val || val.querySelector('.tgl')) return; // toggle rows handled by wireToggles
    const go = fn => { val.style.cursor = 'pointer'; row.style.cursor = 'pointer'; row.onclick = () => { Promise.resolve().then(fn).catch(e => showSvcError(e)); }; };
    if (currentScreen === 'warp' && /endpoint/i.test(nm)) go(cycleWarpEndpoint);
    else if (currentScreen === 'lantern' && /server selection/i.test(nm)) go(() => cycleLanternServer(val));
    else if (currentScreen === 'v2ray' && /subscriptions/i.test(nm)) go(() => { location.hash = '#/servers'; });
    else if (currentScreen === 'v2ray' && /(routing|dns)/i.test(nm)) go(() => { location.hash = '#/settings'; });
    else if (currentScreen === 'openvpn' && /import/i.test(nm)) go(() => pickImportFile());
    else if (currentScreen === 'urnetwork' && /managed profiles/i.test(nm)) go(() => { location.hash = '#/servers'; });
    else if ((currentScreen === 'emberwarp' || currentScreen === 'masque') && /protocol/i.test(nm)) {
      go(() => { location.hash = currentScreen === 'emberwarp' ? '#/masque' : '#/emberwarp'; });
    }
    else if (/core/i.test(nm)) disableWithReason(val, 'Bundled core — nothing to configure.');
    else if (currentScreen === 'mozilla') disableWithReason(val, 'Mozilla account controls are not available in the Windows shell yet.');
    else if (currentScreen === 'warp' && /mode/i.test(nm)) disableWithReason(val, 'Only plain WARP exists on Windows; the other modes live in Android Settings.');
    else if (currentScreen === 'psiphon') disableWithReason(val, 'Psiphon picks its region and egress itself; nothing to configure here.');
    else if (currentScreen === 'openvpn' && /auth/i.test(nm)) disableWithReason(val, 'OpenVPN credential entry is not part of this build; auth requests surface in the engine state.');
    else if (currentScreen === 'wireguard' && /dns/i.test(nm)) disableWithReason(val, 'DNS is taken from the tunnel config.');
    else if (currentScreen === 'urnetwork') disableWithReason(val, 'The URnetwork source page is not part of this build.');
    else if (currentScreen === 'v2ray') disableWithReason(val, 'Owned by the Ember service; nothing to configure.');
    else disableWithReason(val, 'Nothing to configure here in this build.');
  });
}

/* ---------- Settings page (existing page only, H-4) ---------- */
const DNS_PRESETS = {
  'Global': 'https://dns.google/dns-query',
  'Shecan': 'https://free.shecan.ir/dns-query',
  'Electro': '78.157.42.100,78.157.42.101',
  '403.online': '10.202.10.202,10.202.10.102',
  'RadarGame': '10.202.10.10,10.202.10.11',
  'Begzar': '185.55.226.26,185.55.225.25',
};
const ROUTING_PRESETS = { 'Global': 'global', 'Bypass LAN': 'bypass-lan', 'Bypass Iran': 'bypass-iran', 'Direct all': 'direct-all' };
const DOMAIN_STRATEGIES = ['AsIs', 'IPIfNonMatch', 'IPOnDemand'];
function selectChip(container, chip) {
  container.querySelectorAll('.pchip').forEach(c => c.classList.remove('sel', 'fill'));
  chip.classList.add('sel');
}
function wireChipGroup(container, onPick) {
  container.querySelectorAll('.pchip').forEach(chip => {
    chip.style.cursor = 'pointer';
    chip.onclick = () => { selectChip(container, chip); onPick(chip.textContent.trim()); };
  });
}
function wireSettingsPage() {
  // Remote DNS: the .fieldbox div becomes a real input bound to
  // settings.remoteDns; its initial value is the STORED value.
  const fb = document.querySelector('#app .fieldbox');
  if (fb) {
    const input = document.createElement('input');
    input.className = 'fieldbox ember-input';
    input.value = settingGet('remoteDns');
    input.spellcheck = false;
    fb.replaceWith(input);
    input.onchange = async () => {
      await persistSetting('remoteDns', input.value.trim());
      markDnsPresetSelection();
    };
    input.oninput = () => markDnsPresetSelection();
  }
  const markDnsPresetSelection = () => {
    const group = [...document.querySelectorAll('#app .pchips')].find(g =>
      [...g.querySelectorAll('.pchip')].some(c => c.textContent.trim() === 'Shecan'));
    if (!group) return;
    const cur = settingGet('remoteDns');
    let matched = false;
    group.querySelectorAll('.pchip').forEach(c => {
      const name = c.textContent.trim();
      const on = name === 'Custom' ? false : DNS_PRESETS[name] === cur;
      if (on) matched = true;
      c.classList.toggle('sel', on); c.classList.remove('fill');
    });
    const custom = [...group.querySelectorAll('.pchip')].find(c => c.textContent.trim() === 'Custom');
    if (custom && !matched) custom.classList.add('sel');
  };
  document.querySelectorAll('#app .pchips').forEach(group => {
    const names = [...group.querySelectorAll('.pchip')].map(c => c.textContent.trim());
    const row = group.closest('.srow');
    const rowLabel = row ? ((row.querySelector('.t') || {}).textContent || '') : '';
    if (names.includes('Shecan')) {
      wireChipGroup(group, async name => {
        if (name === 'Custom') { const i = document.querySelector('#app input.fieldbox'); if (i) i.focus(); return; }
        if (DNS_PRESETS[name]) {
          await persistSetting('remoteDns', DNS_PRESETS[name]);
          const i = document.querySelector('#app input.fieldbox');
          if (i) i.value = DNS_PRESETS[name];
        }
      });
      markDnsPresetSelection();
    } else if (names.some(n => n in ROUTING_PRESETS)) {
      const cur = settingGet('routingPreset');
      group.querySelectorAll('.pchip').forEach(c => {
        c.classList.toggle('sel', ROUTING_PRESETS[c.textContent.trim()] === cur);
        c.classList.remove('fill');
      });
      wireChipGroup(group, async name => { if (ROUTING_PRESETS[name]) await persistSetting('routingPreset', ROUTING_PRESETS[name]); });
    } else if (/capture mode/i.test(rowLabel)) {
      const isTun = settingGet('tunMode') !== false;
      group.querySelectorAll('.pchip').forEach(c =>
        c.classList.toggle('sel', /tun/i.test(c.textContent) === isTun));
      wireChipGroup(group, async name => {
        const tun = /tun/i.test(name);
        await persistSetting('tunMode', tun);
        await persistSetting('systemProxy', !tun);
      });
    } else {
      group.querySelectorAll('.pchip').forEach(c => disableWithReason(c, 'This chip group is not bound to a setting in this build.'));
    }
  });
  // Chevron .val rows.
  document.querySelectorAll('#app .srow').forEach(row => {
    const label = ((row.querySelector('.t') || {}).textContent || '').trim();
    const val = row.querySelector('.val');
    if (!val || val.querySelector('.tgl')) return;
    if (/language/i.test(label)) disableWithReason(val, 'English only in this build');
    else if (/app lock/i.test(label)) disableWithReason(val, 'Not available on Windows yet');
    else if (/check for updates/i.test(label)) {
      val.style.cursor = 'pointer';
      val.onclick = async () => { await checkUpdate(); };
    } else if (/domain strategy/i.test(label)) {
      val.textContent = settingGet('domainStrategy') + ' ›';
      val.style.cursor = 'pointer';
      val.onclick = async () => {
        const cur = settingGet('domainStrategy');
        const next = DOMAIN_STRATEGIES[(DOMAIN_STRATEGIES.indexOf(cur) + 1) % DOMAIN_STRATEGIES.length];
        await persistSetting('domainStrategy', next);
        val.textContent = next + ' ›';
      };
    } else if (/custom rules/i.test(label)) disableWithReason(val, 'No custom-rules editor on Windows yet.');
    else if (/settings vault/i.test(label)) { /* static status text, not a control */ }
    else if (/diagnostics/i.test(label)) disableWithReason(val, 'Diagnostics are not available on Windows yet.');
    else if (/licences/i.test(label)) disableWithReason(val, 'The licence list is not bundled in this build.');
    else if (/ralysnd ember for windows/i.test(label)) { if (meta.version) val.textContent = meta.version; }
    else if (val.querySelector('.chev') || /›/.test(val.textContent)) disableWithReason(val, 'Nothing to open here in this build.');
  });
  // "Send problem report" — no report machinery on Windows yet.
  document.querySelectorAll('#app .sendbtn').forEach(b =>
    disableWithReason(b, 'Problem reports are not available on Windows yet.'));
}

/* ---------- Servers page (B-3/H-5) ---------- */
const PROTO_LABEL = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', ss: 'Shadowsocks', wireguard: 'WireGuard', openvpn: 'OpenVPN', hysteria2: 'Hysteria2' };
const CHIP_TO_PROTO = { 'All': 'all', 'VLESS': 'vless', 'VMess': 'vmess', 'Trojan': 'trojan', 'Shadowsocks': 'ss', 'WireGuard': 'wireguard', 'Hysteria2': 'hysteria2' };
function protoGlyph(p) { return (PROTO_LABEL[p.protocol] || p.protocol || '??').slice(0, 2).toUpperCase(); }
function renderServersPage() {
  const list = document.querySelector('.srvlist');
  if (!list) return;
  const profiles = store.profiles || [];
  list.innerHTML = '';
  const head = document.createElement('div');
  head.className = 'growhead';
  head.innerHTML = `<div><span class="micro">My configs</span><div class="ds">${profiles.length} config(s) stored on this device</div></div>`;
  list.appendChild(head);
  let shown = 0;
  for (const p of profiles) {
    if (serversFilter !== 'all' && p.protocol !== serversFilter) continue;
    if (serversQuery && !(p.name + ' ' + p.address + ' ' + p.protocol).toLowerCase().includes(serversQuery)) continue;
    shown++;
    const row = document.createElement('div');
    row.className = 'srvrow' + (p.id === store.selectedProfileId ? ' sel' : '');
    const pingTxt = p.ping != null ? `${p.ping} ms<small>${p.ping < 150 ? 'healthy' : p.ping < 400 ? 'ok' : 'slow'}</small>` : '— ms<small>untested</small>';
    const pingColor = p.ping == null ? 'var(--faint)' : p.ping < 150 ? 'var(--green)' : p.ping < 400 ? 'var(--amber)' : 'var(--red)';
    const insecure = p.protocol === 'ss' || p.security === 'none';
    row.innerHTML = `<div class="flagc">${esc(protoGlyph(p))}</div>
      <div class="grow"><div class="nm">${esc(p.name)}</div>
      <div class="meta">${esc(PROTO_LABEL[p.protocol] || p.protocol)} · ${esc(p.security || '')} · ${esc(p.address)}:${p.port}</div>
      ${insecure ? '<span class="badge-ns">Not secure — unencrypted</span>' : ''}</div>
      <div class="pingc" style="color:${pingColor}">${pingTxt}</div>
      <span class="kebab" title="Rename / delete">⋮</span>`;
    row.style.cursor = 'pointer';
    row.onclick = async () => {
      store.selectedProfileId = p.id;
      await window.ember.store.set('selectedProfileId', p.id);
      renderServersPage();
    };
    const kebab = row.querySelector('.kebab');
    kebab.onclick = ev => {
      ev.stopPropagation();
      showMenu(kebab, [
        { label: 'Rename', fn: async () => {
            const name = await emberPrompt('Rename profile', p.name);
            if (!name || !name.trim()) return;
            p.name = name.trim();
            await persistProfiles(); renderServersPage();
          } },
        { label: 'Delete', fn: async () => {
            if (!(await emberConfirm('Delete "' + p.name + '"?'))) return;
            store.profiles = (store.profiles || []).filter(x => x.id !== p.id);
            if (store.selectedProfileId === p.id) {
              store.selectedProfileId = store.profiles.length ? store.profiles[0].id : null;
              await window.ember.store.set('selectedProfileId', store.selectedProfileId);
            }
            await persistProfiles(); renderServersPage();
          } },
      ]);
    };
    list.appendChild(row);
  }
  if (!shown) {
    const empty = document.createElement('div');
    empty.className = 'srvrow';
    empty.innerHTML = '<div class="grow"><div class="nm">No configs yet</div><div class="meta">Use Import above — paste a link, import a .conf / .ovpn file, or add a subscription.</div></div>';
    list.appendChild(empty);
  }
  renderInspector();
}
function renderInspector() {
  const insp = document.querySelector('.insp');
  if (!insp) return;
  const p = selectedProfile();
  if (!p) {
    insp.innerHTML = `<div class="micro" style="color:var(--faint)">Selected config</div>
      <div class="nm">No config selected</div>
      <div class="ds" style="margin-top:8px">Import a config with the toolbar — paste a link, import a file, or add a subscription.</div>`;
    return;
  }
  insp.innerHTML = `<div class="micro" style="color:var(--faint)">Selected config</div>
    <div class="nm">${esc(p.name)}</div>
    <div class="heroping"><span class="n">${p.ping != null ? p.ping : '—'}</span><span class="ms">ms</span></div>
    <div class="health"><span class="d"></span>${p.ping != null ? 'TESTED · TCP PING' : 'UNTESTED'}</div>
    <div class="facts">
      <div class="fact"><span class="k">Protocol</span><span class="v">${esc(PROTO_LABEL[p.protocol] || p.protocol)} · ${esc(p.security || '')}</span></div>
      <div class="fact"><span class="k">Address</span><span class="v">${esc(p.address)} : ${p.port}</span></div>
      <div class="fact"><span class="k">Engine</span><span class="v">${esc(ENGINE_LABEL[p.engine] || p.engine || '')}</span></div>
    </div>
    <div class="connectbtn">CONNECT</div>
    <div class="diag"><div class="b" id="insp-ping">Ping</div></div>`;
  const cb = insp.querySelector('.connectbtn');
  cb.style.cursor = 'pointer';
  cb.onclick = async () => {
    if (p.engine) { await window.ember.store.set('selectedEngine', p.engine); store.selectedEngine = p.engine; }
    toggleConnect(p.engine || 'v2ray');
  };
  const pingBtn = insp.querySelector('#insp-ping');
  pingBtn.style.cursor = 'pointer';
  pingBtn.onclick = async () => { await pingProfileInto(p, pingBtn); renderServersPage(); };
}
function wireServersPage() {
  renderServersPage();
  const search = document.querySelector('.search');
  if (search) {
    search.innerHTML = '<input id="srv-q" placeholder="Search servers" style="flex:1;background:none;border:none">';
    document.getElementById('srv-q').oninput = e => { serversQuery = e.target.value.toLowerCase(); renderServersPage(); };
  }
  document.querySelectorAll('.tbtn').forEach(b => {
    const label = b.textContent.trim();
    b.style.cursor = 'pointer';
    if (/import/i.test(label)) {
      b.onclick = () => showMenu(b, [
        { label: 'Paste link…', fn: async () => {
            const text = await emberPrompt('Paste one or more config links (vless://, vmess://, trojan://, ss://):');
            if (!text) return;
            try { showSvcNote(await importLinksText(text)); } catch (e) { showSvcError(e); }
          } },
        { label: 'Import file (.conf / .ovpn)…', fn: () => pickImportFile() },
        { label: 'Add subscription…', fn: async () => {
            const url = await emberPrompt('Subscription URL:');
            if (!url) return;
            try { showSvcNote(await importSubscription(url.trim())); } catch (e) { showSvcError(e); }
          } },
      ]);
    } else if (/ping all/i.test(label)) {
      b.onclick = async () => {
        for (const p of store.profiles || []) {
          const r = await window.ember.tcpPing(p.address, p.port, 3000).catch(() => ({ ok: false }));
          p.ping = r.ok ? r.ms : null;
        }
        await persistProfiles(); renderServersPage();
      };
    } else disableWithReason(b, 'No action is bound to this button in this build.');
  });
  document.querySelectorAll('.fchip').forEach(chip => {
    const key = CHIP_TO_PROTO[chip.textContent.trim()];
    chip.style.cursor = 'pointer';
    chip.onclick = () => {
      serversFilter = key || 'all';
      document.querySelectorAll('.fchip').forEach(c => c.classList.toggle('sel', c === chip));
      renderServersPage();
    };
  });
}

/* ---------- URnetwork account form (unchanged behaviour) ---------- */
function wireUrForm() {
  const rows = document.querySelector('.rows');
  if (!rows || document.getElementById('ur-form')) return;
  const div = document.createElement('div');
  div.className = 'krow'; div.id = 'ur-form';
  div.innerHTML = `<div class="t"><div class="nm">Add account</div><div class="ds">API key is stored encrypted (safeStorage) — never in the state file.</div></div>
    <div class="val"><input id="ur-label" placeholder="Label"><input id="ur-key" type="password" placeholder="API key">
    <button class="chipbtn o" id="ur-add">Add</button></div>`;
  rows.appendChild(div);
  document.getElementById('ur-add').onclick = async () => {
    const label = document.getElementById('ur-label').value.trim();
    const key = document.getElementById('ur-key').value.trim();
    if (!label || !key) return;
    const id = 'ur-' + Date.now();
    await window.ember.secrets.set('urnetwork:' + id, key);
    store.urnetworkAccounts = [...(store.urnetworkAccounts || []), { id, label }];
    await window.ember.store.set('urnetworkAccounts', store.urnetworkAccounts);
    document.getElementById('ur-key').value = '';
  };
}

function wireControls() {
  wireToggles();
  // Connect / disconnect: pills AND the round buttons beside them.
  document.querySelectorAll('#app .pill, #app .round').forEach(el => {
    el.style.cursor = 'pointer';
    el.onclick = () => toggleConnect(engineOf(currentScreen));
  });
  document.querySelectorAll('[data-action="update"]').forEach(b => b.onclick = checkUpdate);
  document.querySelectorAll('[data-action="install-service"]').forEach(b => b.onclick = installService);
  wireChipbtns();
  wireKrows();
  if (currentScreen === 'settings') wireSettingsPage();
  if (currentScreen === 'servers') wireServersPage();
  if (currentScreen === 'urnetwork') wireUrForm();
}

/* ---------- connect orchestration ---------- */
async function toggleConnect(engine) {
  if (!engine || !CTRLS[engine]) return;
  const c = CTRLS[engine];
  try {
    if (engine === 'lantern') {
      if (engineState.get('lantern') === 'Connected') await c.disconnect(); else await c.connect(store.lantern && store.lantern.selectedServer);
    } else if (engine === 'warp') {
      await c.toggle();
    } else if (engine === 'v2ray' || engine === 'urnetwork') {
      if (c.running) await c.stop();
      else {
        const p = selectedProfileFor(engine);
        if (!p) throw new Error('No ' + ENGINE_LABEL[engine] + ' config selected — import one on the Servers page first.');
        if (!['vless', 'vmess', 'trojan', 'ss'].includes(p.protocol)) {
          throw new Error('Profile "' + p.name + '" (' + p.protocol + ') cannot run on the Xray engine.');
        }
        const cfg = EP.buildXrayConfig(p, {
          socksPort: (c.cfg && c.cfg.socksPort) || settingGet('socksPort'),
          remoteDns: settingGet('remoteDns'),
          domainStrategy: settingGet('domainStrategy'),
          routingPreset: settingGet('routingPreset'),
          sniffing: settingGet('sniffing'),
          fakeDns: settingGet('fakeDns'),
        });
        await c.start([], JSON.stringify(cfg, null, 1));
      }
    } else if (engine === 'wireguard') {
      if (c.running) await c.stop();
      else {
        const p = selectedProfileFor('wireguard');
        if (!p || !p.confText) throw new Error('No WireGuard config selected — import a .conf profile first.');
        // The selected profile's identity names the tunnel on the
        // service (audit W5) — never a shared constant.
        await c.start(p.confText, p.name || p.id);
      }
    } else if (engine === 'openvpn') {
      await c.toggle(selectedProfileFor('openvpn'));
    } else await c.toggle();
  } catch (e) { showSvcError(e); engineState.set(engine, 'Failed'); }
  refreshRailStates(); refreshConnectBar();
}

/* ---------- service bar: tri-state truthfulness (H-1/M-3) ----------
 * svc:status / service.state snapshots resolve to exactly:
 *   {state:'running', detail?} | {state:'error', error} | {state:'absent', error}
 * A sticky real error (engine failure, install failure) is never
 * overwritten by a later generic state event; it clears only when
 * the user dismisses it or the service reaches 'running'. */
let svcStickyError = null, svcStickyNote = null, svcInstalling = false;
async function refreshServiceBar(snap) {
  const st = snap || await window.ember.serviceStatus().catch(() => ({ state: 'error', error: 'status check failed' }));
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  const installBtn = document.getElementById('svcinstall');
  const acctSvc = document.getElementById('acct-svc');
  if (!bar || !word) return;
  if (st.state === 'running') {
    svcStickyError = null; // state changed to running — the error's cause is gone
    if (acctSvc) acctSvc.textContent = 'Running.';
    if (svcStickyNote) { word.textContent = svcStickyNote; bar.classList.add('show'); }
    else bar.classList.remove('show');
    return;
  }
  if (!meta.shoot) bar.classList.add('show');
  if (installBtn) installBtn.style.display = st.state === 'absent' ? '' : 'none';
  if (svcInstalling) { word.textContent = 'Installing the Ember service — approve the elevation prompt…'; return; }
  if (st.state === 'error' && st.error === 'connecting') {
    // Pre-hello sentinel (audit W12): the service may well be
    // installed and starting — render a neutral connecting bar,
    // WITHOUT the Install button and without "not installed".
    word.textContent = 'Connecting to the Ember service…';
    if (installBtn) installBtn.style.display = 'none';
    if (acctSvc) acctSvc.textContent = 'Connecting…';
    return;
  }
  if (svcStickyError) { word.textContent = svcStickyError; return; }
  if (st.state === 'error') {
    word.textContent = 'Ember service error — ' + (st.error || 'the service answered but its status check failed.');
    if (acctSvc) acctSvc.textContent = 'Error: ' + (st.error || 'unknown');
  } else { // absent — the ONLY state that may say "not installed"
    word.textContent = 'Service not installed — engine actions are unavailable until the Ember service is installed.' +
      (st.error ? ' (' + st.error + ')' : '');
    if (acctSvc) acctSvc.textContent = 'Not installed.';
  }
}
function showSvcError(e) {
  svcStickyError = 'Ember service: ' + (e && e.message ? e.message : String(e));
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  if (word) word.textContent = svcStickyError;
  if (bar) bar.classList.add('show');
}
function showSvcNote(text) {
  svcStickyNote = String(text);
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  if (word && !svcStickyError) word.textContent = svcStickyNote;
  if (bar) bar.classList.add('show');
}
async function installService() {
  if (svcInstalling) return;
  svcInstalling = true; svcStickyError = null; svcStickyNote = null;
  const btn = document.getElementById('svcinstall');
  const old = btn ? btn.textContent : '';
  if (btn) { btn.textContent = 'Installing…'; btn.classList.add('dis'); }
  refreshServiceBar({ state: 'absent' });
  // svc:install resolves {ok, code, message} only after the verb
  // finishes — `message` carries the real outcome either way.
  const r = await window.ember.installService().catch(e => ({ ok: false, code: null, message: String(e.message || e) }));
  svcInstalling = false;
  if (btn) { btn.textContent = old; btn.classList.remove('dis'); }
  if (r.ok) {
    svcStickyNote = 'Ember service installed — ' + (r.message || 'install finished.');
    await refreshServiceBar();
    if (!document.getElementById('svcbar').classList.contains('show')) showSvcNote(svcStickyNote);
    else document.getElementById('svcword').textContent = svcStickyNote;
  } else {
    showSvcError(new Error('Service install failed: ' + (r.message || 'unknown error')));
  }
}
async function checkUpdate() {
  const word = document.getElementById('update-word');
  const r = await window.ember.updater.check();
  if (r.available) {
    if (word) word.textContent = `Version ${r.version} is available (${r.name}).`;
    if (await emberConfirm(`Ralysnd Ember ${r.version} is available. Open the download page?`)) window.ember.openExternal(r.url);
  } else if (word) word.textContent = r.reason || 'You are up to date.';
  // The Settings "Check for updates" row shows the outcome too.
  document.querySelectorAll('#app .srow').forEach(row => {
    const label = ((row.querySelector('.t') || {}).textContent || '');
    const val = row.querySelector('.val');
    if (val && /check for updates/i.test(label)) val.textContent = r.available ? (r.version + ' available ›') : 'Up to date ›';
  });
}

async function boot() {
  templates = await (await fetch('templates.json')).json();
  meta = await window.ember.meta();
  store = await window.ember.store.get();
  window.__emberSettings = store.settings || {};
  window.__appRoot = meta.appRoot || null;
  if (meta.shoot && !(store.profiles || []).length) {
    store.profiles = DEMO_PROFILES; store.selectedProfileId = 'demo-1'; store.selectedEngine = 'mozilla';
    await window.ember.store.set('profiles', DEMO_PROFILES);
    await window.ember.store.set('selectedProfileId', 'demo-1');
  }
  if (meta.shoot) {
    // The connected demo state lives only on its own screen,
    // in the rail as in the page (set per render below).
    window.__shootConnected = true;
  }
  wireServiceEvents();
  // Boot reconciliation (audit W3): the first time the service
  // reports running, adopt whatever engines it already holds —
  // with the same proofs as a fresh connect (controllers.reconcile).
  let reconciled = false;
  const maybeReconcile = data => {
    if (reconciled || !data || data.state !== 'running') return;
    reconciled = true;
    const wgProfileNames = (store.profiles || []).filter(p => p.engine === 'wireguard')
      .map(p => p.name || p.id);
    reconcile({ wgProfileNames }).catch(() => {});
  };
  window.__onServiceState = data => { refreshServiceBar(data); maybeReconcile(data); };
  engineState.on(() => { refreshRailStates(); refreshConnectBar(); });
  window.addEventListener('hashchange', render);
  document.getElementById('svcinstall').onclick = installService;
  const dismiss = document.getElementById('svcdismiss');
  if (dismiss) dismiss.onclick = () => {
    svcStickyError = null; svcStickyNote = null;
    refreshServiceBar();
  };
  render();
  // The service may already be running before the first state
  // event arrives — check once so reconciliation is not missed.
  window.ember.serviceStatus().then(st => { if (st) maybeReconcile(st); }).catch(() => {});
}
boot().catch(e => { document.getElementById('app').textContent = 'Failed to start: ' + e.message; });
