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
const LOGS = window.EmberControllers.logs;
const BYEDPI = window.EmberControllers.byedpi;
const REGIONHOP = window.EmberControllers.regionhop;
const ZAPRET_STRATEGIES = window.EmberControllers.ZAPRET_STRATEGIES || [];
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
  // 2042 Phase 3 (UI-S-A keys; consumers in profiles.js / controllers.js).
  autoConnect: false,
  dnsPreset: 'google', dnsTransport: 'doh', localDns: '8.8.8.8',
  listenAddress: '127.0.0.1', lanSharing: false, lanAuthUser: '',
  regionHopEnabled: false, dpiLabEnabled: false,
  // UI-S-B2 keys (mirror main.js DEFAULT_STATE.settings).
  trafficAccounting: true, sessionBudgetMb: 0,
  sweepAutoCut: false, sweepThreshold: 3,
  subscriptionAutoUpdate: false, subRefreshHours: 24, hwid: '',
  globalShortcut: false,
  // FIX-ROUND2: the owner's standing exception (Android 2151) —
  // the connected-but-blocked alert ships DEFAULT ON, unlike
  // every other Ember-added feature. Consumer: blockedWatcher
  // in this file. (main.js DEFAULT_STATE.settings needs the same
  // key for the persisted default — coordinator wiring item.)
  connectedButBlocked: true,
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
  return ['home', 'home-connected', ...ENGINES, 'servers', 'settings', 'account', 'logs'].includes(h) ? h : 'home';
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
/* Subscriptions (UI-S-B2 task 5): entries are
 * {id, name, url, updatedAt, hwid, autoUpdate, lastFetchedAt} —
 * the B2 fields are additive; older entries are extended in place
 * by normalizeSubscription. HWID mirrors Android exactly
 * (src2 sub_fetcher.dart): a non-empty hwid is sent as the
 * `x-hwid` request header — nothing else, no User-Agent games.
 * A subscription's own hwid wins; new subscriptions inherit the
 * global settings.hwid as their default. */
function normalizeSubscription(s) {
  if (!s || typeof s !== 'object') return s;
  if (s.hwid === undefined) s.hwid = '';
  if (s.autoUpdate === undefined) s.autoUpdate = false;
  if (s.lastFetchedAt === undefined) s.lastFetchedAt = s.updatedAt || 0;
  return s;
}
async function fetchSubscriptionBody(url, hwid) {
  // Prefer the main-process fetch (no CORS limit on subscription hosts);
  // fall back to renderer fetch if the bridge is unavailable.
  if (window.ember.fetchText) {
    const headers = hwid ? { 'x-hwid': hwid } : undefined;
    const r = await window.ember.fetchText(url, headers);
    if (!r.ok) throw new Error('Subscription fetch failed: ' + r.error);
    return r.text;
  }
  const res = await fetch(url, { headers: hwid ? { 'x-hwid': hwid } : {} });
  if (!res.ok) throw new Error('Subscription fetch failed: HTTP ' + res.status);
  return res.text();
}
async function importSubscription(url, existing) {
  const sub = existing ? normalizeSubscription(existing)
    : { id: 'sub-' + Date.now(), name: url, url, updatedAt: 0,
        hwid: settingGet('hwid') || '', autoUpdate: false, lastFetchedAt: 0 };
  const body = await fetchSubscriptionBody(url, sub.hwid || '');
  const { profiles, errors } = EP.parseSubscriptionBody(body);
  if (!profiles.length) throw new Error('No usable configs in that subscription' + (errors.length ? ' (' + errors.length + ' unparseable lines)' : ''));
  if (existing) {
    // Refetch replaces the subscription's previous group members.
    store.profiles = (store.profiles || []).filter(p => p.group !== url);
  }
  profiles.forEach(p => { p.group = url; });
  await addProfiles(profiles);
  sub.updatedAt = Date.now(); sub.lastFetchedAt = Date.now();
  if (!existing) store.subscriptions = [...(store.subscriptions || []), sub];
  await window.ember.store.set('subscriptions', store.subscriptions);
  return profiles.length + ' config(s) imported from the subscription';
}
/* Boot refresh (task 5): when subscriptionAutoUpdate is on,
 * refetch every subscription whose lastFetchedAt is older than
 * subRefreshHours. Boot-check only — no timers. Failures are
 * noted, never fatal to boot. */
async function refreshSubscriptionsOnBoot() {
  if (settingGet('subscriptionAutoUpdate') !== true) return;
  const intervalMs = Math.max(1, Number(settingGet('subRefreshHours') || 24)) * 3600 * 1000;
  const now = Date.now();
  for (const s of (store.subscriptions || []).map(normalizeSubscription)) {
    if (now - (s.lastFetchedAt || 0) < intervalMs) continue;
    try { await importSubscription(s.url, s); }
    catch (e) { showSvcNote('Subscription refresh failed for ' + s.name + ': ' + (e.message || e)); }
  }
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
/* QR image import (2042): decode a QR code from a picked image in
 * the renderer (window.EmberQr, renderer/qr.js + jsQR) and feed the
 * payload — a proxy link, or several one per line — to the same
 * importLinksText flow as Paste link. */
function pickQrImageFile() {
  let inp = document.getElementById('ember-qr-import');
  if (!inp) {
    inp = document.createElement('input');
    inp.type = 'file'; inp.id = 'ember-qr-import'; inp.accept = 'image/*';
    inp.style.display = 'none';
    document.body.appendChild(inp);
    inp.onchange = async () => {
      const file = inp.files && inp.files[0];
      inp.value = '';
      if (!file) return;
      try {
        if (!window.EmberQr) throw new Error('QR import is unavailable in this build.');
        const payload = await window.EmberQr.decodeFromFile(file);
        if (!payload) { await emberConfirm('No QR code found in that image.'); return; }
        showSvcNote(await importLinksText(payload));
      } catch (e) { showSvcError(e); }
    };
  }
  inp.click();
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
function emberDialog(message, withInput, initial, inputType) {
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
      input.className = 'ember-dialog-input'; input.type = inputType || 'text';
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
const emberPrompt = (message, initial, inputType) => emberDialog(message, true, initial, inputType);
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

/* ---------- shared titlebar (Round-1 F2) ----------
 * The JS-rendered pages (account, logs) carry the SAME titlebar
 * markup as the templates: the .tr utility icons plus the
 * #win-min/#win-max/#win-close window controls (the EMBER wordmark
 * itself lives in the rail's .brand). One constant, used by both
 * renderers; render() calls wireWindowControls() on every render,
 * so the controls bind on these pages exactly as on templated ones. */
const TITLEBAR_HTML = `<div class="titlebar"><div class="tr"><div class="icobtn"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#C9C9CC" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/></svg></div><div class="icobtn"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#C9C9CC" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v3M12 18.2v3M2.8 12h3M18.2 12h3M5.5 5.5l2.1 2.1M16.4 16.4l2.1 2.1M18.5 5.5l-2.1 2.1M7.6 16.4l-2.1 2.1"/></svg></div><div class="avatar">R</div></div><div class="winbtns"><button class="winbtn" id="win-min" aria-label="Minimize"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"><path d="M1 5.5h9"/></svg></button><button class="winbtn" id="win-max" aria-label="Maximize or restore"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="1.5" y="1.5" width="8" height="8" rx="1"/></svg></button><button class="winbtn close" id="win-close" aria-label="Close"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"><path d="M1.5 1.5l8 8M9.5 1.5l-8 8"/></svg></button></div></div>`;

function accountHTML() {
  const rail = extractRail(templates.settings).replace('navrow on', 'navrow');
  return `<div class="stage"><div class="map"><img src="../assets/map_backdrop_home.webp" alt=""></div><div class="faint"></div>
  ${TITLEBAR_HTML}
  ${rail}
  <div class="content"><div class="phead"><div><div class="micro-o">Ralysnd Ember</div>
  <div class="hero" style="margin-top:10px"><div class="word" style="font-size:40px">Account</div>
  <div class="sub">Version <b id="acct-ver">2.2.0</b> · Electron shell, Go service engine layer</div></div></div></div>
  <div class="rows">
    <div class="krow"><div class="t"><div class="nm">Check for updates</div><div class="ds">Offers a download only when the latest GitHub release carries a Windows Setup .exe.</div></div>
    <div class="val"><button class="chipbtn o" data-action="update">Check</button></div></div>
    <div class="krow"><div class="t"><div class="nm">Update status</div><div class="ds" id="update-word">Not checked yet.</div></div><div class="val"></div></div>
    <div class="krow"><div class="t"><div class="nm">Ember service</div><div class="ds" id="acct-svc">State unknown.</div></div>
    <div class="val" id="acct-svc-val"><button class="chipbtn" data-action="install-service">Install the Ember service</button></div></div>
  </div></div></div>`;
}

function render() {
  stopUrPolling(); // UR polling lives only while its page is shown (task 10)
  currentScreen = route();
  let html;
  if (currentScreen === 'account') html = accountHTML();
  else if (currentScreen === 'logs') html = logsHTML();
  else html = templates[currentScreen] || templates.home;
  document.getElementById('app').innerHTML = html;
  if (window.__shootConnected) {
    engineState.set('v2ray', currentScreen === 'home-connected' ? 'Connected' : 'Idle');
  }
  fitStage();
  document.querySelectorAll('.map img').forEach(img => { img.src = '../assets/map_backdrop_home.webp'; });
  wireRail(); wireWindowControls(); wireControls(); refreshRailStates(); refreshConnectBar(); refreshServiceBar();
  if (pendingCardScroll && currentScreen === 'settings') {
    const t = pendingCardScroll; pendingCardScroll = null; scrollToCard(t);
  }
  const v = document.getElementById('acct-ver'); if (v && meta.version) v.textContent = meta.version;
}

// The stage is a fixed 1440x900 composition; scale it to the
// window by the SMALLER of the two axis ratios and centre the
// scaled box on both axes. The stage is absolutely positioned
// with transform-origin 0 0, so left/top place the scaled box
// directly: left = (vw - 1440*s)/2, top = (vh - 900*s)/2. At
// 1440x900 that is scale 1 with zero offset — pixel-identical
// to the unscaled composition. (Scaling by width alone, with
// the stage anchored top-left, clipped the bottom ~80px at
// 1280x720: the home state bar and the rail ACCOUNT footer.)
// The .svcbar is position:fixed OUTSIDE the stage, so it is
// unaffected by the scale and stays visible/clickable.
function fitStage() {
  const stage = document.querySelector('.stage');
  if (!stage) return;
  // FIX-ADV L5: clamp the upscale to 1.5 — beyond that the fixed
  // 1440x900 stage (including the raster map backdrop) just goes
  // soft and compositing gets heavy; the letterbox centring
  // below absorbs the slack on very large displays.
  const s = Math.min(window.innerWidth / 1440, window.innerHeight / 900, 1.5);
  stage.style.left = ((window.innerWidth - 1440 * s) / 2) + 'px';
  stage.style.top = ((window.innerHeight - 900 * s) / 2) + 'px';
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

/* ---------- honest page painting (Round-1 F5: the fiction purge) ----------
 * Templates carry honest empty states only. Every dynamic slot is
 * painted here at render time from real state — store.profiles,
 * store.settings, store.subscriptions, store.urnetworkAccounts,
 * the controllers / engineState — or left at its empty state.
 * Nothing below invents a value: a slot with no real source
 * paints '—'. */
function fmtStat(bytes) {
  const s = fmtBytes(bytes || 0);
  const m = /^([\d.]+)\s*(.*)$/.exec(s);
  return m ? { n: m[1], u: m[2] } : { n: s, u: '' };
}
function setStat(card, label, value) {
  if (!card) return;
  card.querySelectorAll('.stat').forEach(st => {
    const l = st.querySelector('.l'); const n = st.querySelector('.n');
    if (l && n && l.textContent.trim().toLowerCase() === label) {
      if (value === null) { n.innerHTML = '—'; return; }
      const f = fmtStat(value);
      n.innerHTML = esc(f.n) + (f.u ? '<small> ' + esc(f.u) + '</small>' : '');
    }
  });
}
function cardByHead(root, re) {
  return [...root.querySelectorAll('.gcard')].find(c => {
    const h = c.querySelector('.head .micro');
    return h && re.test(h.textContent);
  }) || null;
}
function setCard(card, tag, big, line) {
  if (!card) return;
  const t = card.querySelector('.head .tag');
  if (t && tag !== null) t.textContent = tag;
  const b = card.querySelector('.big');
  if (b && big !== null) b.textContent = big;
  const l = card.querySelector('.line');
  if (l && line !== null) l.textContent = line;
}
function krowVal(nameRe) {
  const row = [...document.querySelectorAll('#app .krow')].find(r => {
    const nm = r.querySelector('.nm');
    return nm && nameRe.test(nm.textContent);
  });
  return row ? row.querySelector('.val') : null;
}
function setHeroSub(suffix) {
  const sub = document.querySelector('#app .hero .sub');
  if (!sub) return;
  const eng = engineOf(currentScreen);
  const word = eng ? engineState.get(eng) : 'Idle';
  const wtxt = word === 'Idle' ? 'disconnected' : String(word).toLowerCase();
  sub.innerHTML = 'Status <b>' + esc(wtxt) + '</b>' + (suffix ? ' — ' + esc(suffix) : '');
}
/* The connect bar's cells + micro-line, from real state only:
 * Location / Exit IP have no live source in the shell (no exit
 * probe) and stay '—'; Up/Down come from the connected profile's
 * persisted traffic counters; the micro-line is the engine name
 * (the template's baked session timer was fiction). The
 * home-connected exit marker + arc show only while connected. */
function paintBarCells(eng, connected) {
  const ml = document.querySelector('.bar .staterow .micro-line');
  if (ml) ml.textContent = (ENGINE_LABEL[eng] || eng || '').toUpperCase();
  const p = connected ? selectedProfileFor(eng) : null;
  document.querySelectorAll('.bar .cells .cell').forEach(cell => {
    const l = cell.querySelector('.l'); const v = cell.querySelector('.v');
    if (!l || !v) return;
    const name = l.textContent.trim().toLowerCase();
    if (name === 'up') v.textContent = p ? fmtBytes(p.upBytes || 0) : '—';
    else if (name === 'down') v.textContent = p ? fmtBytes(p.downBytes || 0) : '—';
    else v.textContent = '—';
  });
  document.querySelectorAll('.exit-marker, .arc').forEach(el => {
    el.style.display = connected ? '' : 'none';
  });
}
const ROUTING_LABELS = { 'global': 'Global', 'bypass-lan': 'Bypass LAN', 'bypass-iran': 'Bypass Iran', 'direct-all': 'Direct all' };
function paintEnginePage() {
  const eng = currentScreen;
  if (!ENGINES.includes(eng)) return;
  const profiles = store.profiles || [];
  if (eng === 'v2ray') {
    const mine = profiles.filter(p => p.engine === 'v2ray');
    const p = selectedProfileFor('v2ray');
    setHeroSub(mine.length
      ? mine.length + ' config(s) on this machine; the selected one rides the connect bar.'
      : 'no configs yet; import one on the Servers page.');
    const card = cardByHead(document, /selected config/i);
    if (p) {
      const bits = [p.address + ':' + p.port];
      if (p.ping != null) bits.push('last ping ' + p.ping + ' ms');
      setCard(card, (PROTO_LABEL[p.protocol] || p.protocol) + (p.security ? ' · ' + p.security : ''),
        p.name, bits.join(' · ') + '. The connect bar runs this config; Servers holds the full list.');
    }
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', profiles.reduce((a, x) => a + (x.upBytes || 0), 0));
    setStat(sess, 'downloaded', profiles.reduce((a, x) => a + (x.downBytes || 0), 0));
    setStat(sess, 'exit', null);
    const line = sess && sess.querySelector('.line');
    if (line) line.textContent = 'Per-config traffic is counted and kept, as on Android — ' + profiles.length + ' config(s) on this machine.';
    const subVal = krowVal(/subscriptions/i);
    if (subVal) subVal.innerHTML = (store.subscriptions || []).length + ' list(s) <span class="chev">›</span>';
    const rtVal = krowVal(/^routing$/i);
    if (rtVal) rtVal.innerHTML = esc(ROUTING_LABELS[settingGet('routingPreset')] || 'Global') + ' <span class="chev">›</span>';
    const dnsVal = krowVal(/^dns$/i);
    if (dnsVal) {
      const dp = settingGet('dnsPreset');
      dnsVal.innerHTML = esc(dp === 'cloudflare' ? 'Cloudflare' : dp === 'custom' ? 'Custom' : 'Global') + ' <span class="chev">›</span>';
    }
  } else if (eng === 'mozilla') {
    setHeroSub('account state is read from the running core.');
    paintMozillaAccount();
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
  } else if (eng === 'lantern') {
    const priv = (store.lantern && (store.lantern.privateServer || store.lantern.selectedServer)) || null;
    const card = cardByHead(document, /private server/i);
    if (priv) {
      setCard(card, 'Added', typeof priv === 'string' ? priv : (priv.name || 'Your own Lantern server'),
        'Added by lantern:// link. When selected, Lantern exits through your server instead of the public network.');
      const fr = card && card.querySelector('.footrow');
      if (fr) fr.innerHTML = '<span class="chipbtn o">Use this server</span><span class="chipbtn">Remove</span>';
    }
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
    CTRLS.lantern.selected().then(sel => {
      const val = krowVal(/server selection/i);
      if (val && sel) val.innerHTML = esc(sel.name || sel.id || sel.serverId || 'Automatic') + ' <span class="chev">›</span>';
    }).catch(() => {});
  } else if (eng === 'wireguard') {
    const mine = profiles.filter(p => p.engine === 'wireguard');
    const p = selectedProfileFor('wireguard');
    setHeroSub(mine.length
      ? mine.length + ' tunnel(s) imported; the selected one rides the connect bar.'
      : 'no tunnels imported yet.');
    const card = cardByHead(document, /selected tunnel/i);
    if (p) {
      const awg = /^\s*(Jc|Jmin|Jmax|S1|S2|H1)\s*=/im.test(p.confText || '');
      const allowed = /AllowedIPs\s*=\s*([^\n]+)/i.exec(p.confText || '');
      setCard(card, awg ? 'AmneziaWG' : 'WireGuard', p.name,
        'Endpoint ' + p.address + ':' + p.port + (allowed ? ' · Allowed IPs ' + allowed[1].trim() : '') +
        '. The AmneziaWG parameters ride inside the config, untouched.');
    }
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', p && (p.upBytes || 0) > 0 ? p.upBytes : null);
    setStat(sess, 'downloaded', p && (p.downBytes || 0) > 0 ? p.downBytes : null);
    setStat(sess, 'last handshake', null);
  } else if (eng === 'warp') {
    const p = CTRLS.warp.profile || store.warpProfile;
    const card = cardByHead(document, /cloudflare warp/i);
    if (p) {
      setCard(card, 'Registered', 'WARP',
        'Registered with Cloudflare — endpoint ' + (p.endpoint || '—') + '. The tunnel itself is an ordinary WireGuard profile on the WireGuard engine.');
    } else {
      setCard(card, 'Not registered', 'WARP',
        'Not registered yet — Register mints this device\u2019s WARP identity with Cloudflare; the tunnel then runs as a WireGuard profile on the WireGuard engine.');
    }
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
  } else if (eng === 'emberwarp' || eng === 'masque') {
    const pick = settingGet('emberwarpEngine') || 'usque';
    const other = pick === 'aether' ? 'usque' : 'aether';
    const card = cardByHead(document, /masque core/i);
    setCard(card, pick + '.exe', null,
      'Connect-IP over HTTP/3, run by ' + pick + '.exe; ' + other + '.exe remains as the fallback core. EmberWarp and MASQUE are the two faces of this one engine.');
    if (card) card.querySelectorAll('.footrow .chipbtn').forEach(b => {
      b.classList.toggle('o', b.textContent.trim().toLowerCase() === eng);
    });
    const cpVal = krowVal(/core pick/i);
    if (cpVal) cpVal.innerHTML = esc(pick) + ' <span class="chev">›</span>';
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
  } else if (eng === 'psiphon') {
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
  } else if (eng === 'openvpn') {
    const mine = profiles.filter(p => p.engine === 'openvpn');
    const p = selectedProfileFor('openvpn');
    setHeroSub(mine.length
      ? mine.length + ' profile(s) imported; the selected one rides the connect bar.'
      : 'no profiles imported yet.');
    const card = cardByHead(document, /selected profile/i);
    if (p) {
      const proto = /^\s*proto\s+(\S+)/im.exec(p.configText || '');
      const auth = /^\s*auth\s+(\S+)/im.exec(p.configText || '');
      const bits = ['Remote ' + p.address + ':' + p.port];
      if (proto) bits.push(proto[1].toUpperCase());
      if (auth) bits.push('auth ' + auth[1]);
      setCard(card, '.ovpn', p.name, bits.join(' · ') + '. Imported profiles keep their own certificates and keys.');
    }
    const sess = cardByHead(document, /session/i);
    setStat(sess, 'uploaded', null); setStat(sess, 'downloaded', null); setStat(sess, 'exit', null);
  } else if (eng === 'urnetwork') {
    paintUrPage();
  }
}
/* Mozilla account card from the core's own status (guardianStatus):
 * signed in only when the core reports an active account; the pass
 * is fresh only when its reported expiry is in the future. Any
 * failure (core not running, dashboard login) paints the honest
 * unknown state with the error as the reason. */
async function paintMozillaAccount() {
  const card = cardByHead(document, /account/i);
  if (!card) return;
  try {
    const st = await CTRLS.mozilla.guardianStatus();
    const acct = st && st.active_account && (st.active_account.email || st.active_account.name);
    const exp = st && st.pass_expires_at ? Number(st.pass_expires_at) : 0;
    const fresh = exp > 0 && exp * 1000 > Date.now();
    if (acct) {
      setCard(card, 'Signed in', acct,
        'Guardian pass ' + (exp ? (fresh ? 'is fresh (expires ' + new Date(exp * 1000).toLocaleString() + ')' : 'has expired — Prepare renews it') : 'state not reported by the core') +
        '. Sign-in tokens stay in the protected vault, never in plain files.');
      setHeroSub('signed in as ' + acct + ' — Guardian pass ' + (fresh ? 'fresh.' : 'not fresh.'));
    } else {
      setCard(card, 'Not signed in', 'Not signed in',
        'The core reports no active account. Sign-in tokens stay in the protected vault, never in plain files.');
      setHeroSub('not signed in — the core reports no active account.');
    }
    const gVal = krowVal(/guardian pass/i);
    if (gVal && exp) gVal.innerHTML = (fresh ? 'Fresh' : 'Expired') + ' <span class="chev">›</span>';
  } catch (e) {
    setCard(card, 'Unknown', 'Account state unknown',
      'The Mozilla core did not answer: ' + (e.message || e));
    setHeroSub('account state unknown — the core did not answer.');
  }
}
/* URnetwork page (Round-1 F5 extension): the ACCOUNT card, SESSION
 * counters and the Managed profiles row all paint from the store;
 * the SDK engine-mode section is painted by wireUrEngineSection
 * from ur.status (and refreshes the Countries stat when the SDK
 * returns a real country list). No plan, balance or country claim
 * is ever baked in. */
function paintUrPage() {
  const accounts = store.urnetworkAccounts || [];
  const card = cardByHead(document, /account/i);
  if (accounts.length) {
    // FIX-ADV L2: say plainly WHICH account a connect will use —
    // the engine connects with the FIRST stored account's key
    // (there is no account picker in this build).
    setCard(card, accounts.length + ' account(s)', accounts[0].label || 'URnetwork account',
      accounts.length + ' account(s) on this machine; keys live in the DPAPI vault. The SDK engine connects with the first account (' +
      (accounts[0].label || 'URnetwork account') + '). Plan and balance come from the SDK session — see the engine state below.');
  }
  const managed = (store.profiles || []).filter(p => /^UR ·/.test(p.name || ''));
  const mpVal = krowVal(/managed profiles/i);
  if (mpVal) mpVal.innerHTML = managed.length + ' profile(s) <span class="chev">›</span>';
}

/* The connect bar mirrors the current engine's state word; the pill
 * flips between CONNECT and DISCONNECT. On Home the approved hero
 * state word (.heroword, Round-1 F3) carries the SAME live word —
 * written here, from the same engineState word, on every refresh:
 * Connected → CONNECTED, Idle → DISCONNECTED, any other state word
 * verbatim uppercased. The .herosub line carries the engine name. */
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
  document.querySelectorAll('.heroword').forEach(w => {
    w.textContent = connected ? 'Connected' : (word === 'Idle' ? 'Disconnected' : word);
    w.classList.toggle('green', connected);
  });
  document.querySelectorAll('.herosub').forEach(el => {
    el.textContent = (ENGINE_LABEL[eng] || eng) + (connected ? ' · tap the ring to disconnect' : ' · tap the ring to connect');
  });
  paintBarCells(eng, connected);
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
      // On Settings the engine pick only re-renders the page: the
      // engine section follows the selected engine (task UI-S-B1-4).
      if (currentScreen === 'settings') { render(); return; }
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
/* Returns {key} for a bound toggle, {custom:'lanAuth'} for the derived
 * LAN-auth toggle, {disabled: reason} for an honest dead-end, or null
 * when the row is handled elsewhere. A toggle is LIVE only when a real
 * consumer reads its key: profiles.js buildXrayConfig's opts, a
 * controller gate, a main-process side effect, or boot behaviour in
 * this file. Everything else is disabled-with-reason — never a
 * write-only switch (owner rule, UI-S-B1 task 3).
 * ctx = { engineSection: bool, engine: <selected engine id> } for
 * rows inside the Settings .engine-section card. */
function engineToggleBinding(l, engine) {
  if (engine === 'v2ray') {
    if (/^sniffing$/.test(l)) return { key: 'sniffing' };
    if (/udp relay/.test(l)) return { disabled: 'The Xray SOCKS inbound always relays UDP in this build (buildXrayConfig sets udp:true) — no setting consumes a UDP-relay switch.' };
    if (/sniff (http|tls|quic)/.test(l)) return { disabled: 'Per-protocol sniffing is not configurable: buildXrayConfig sniffs http+tls whenever sniffing is on, and QUIC sniffing is always off.' };
    if (/block quic/.test(l)) return { disabled: 'No QUIC-blocking rule is emitted by the Xray config builder in this build.' };
  }
  if (engine === 'lantern' && /smart routing/.test(l)) {
    return { disabled: 'Smart routing is not in the service Lantern API allow-list yet.' };
  }
  if (engine === 'urnetwork' && /providing/.test(l)) {
    return { disabled: 'Providing is hard-pinned OFF — this device never becomes an exit for strangers.', forceOff: true };
  }
  if (/kill switch/.test(l)) return { disabled: 'Kill switch is not wired on Windows yet — nothing in the shell or service consumes it.' };
  return { disabled: 'No behaviour is bound to this switch for ' + (ENGINE_LABEL[engine] || 'this engine') + ' in this build.' };
}
function toggleBinding(label, ctx) {
  const l = label.toLowerCase();
  if (ctx && ctx.engineSection) return engineToggleBinding(l, ctx.engine);
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
  if (/connected but blocked/.test(l)) return { key: 'connectedButBlocked' };
  if (/share on lan/.test(l)) return { key: 'lanSharing' };
  if (/require username and password/.test(l)) return { custom: 'lanAuth' };
  if (/connect on startup|auto-connect/.test(l)) return { key: 'autoConnect' };
  if (/auto-update/.test(l)) return { disabled: 'Updates are checked manually in this build — the updater has no background auto-update.' };
  if (/speed in notification/.test(l)) return { disabled: 'The tray tooltip shows the protection state only; live speed is not measured on Windows yet.' };
  if (/notification actions/.test(l)) return { disabled: 'Windows notifications are not part of this shell yet.' };
  if (/browser sign-in fallback/.test(l)) return { disabled: 'There is no account sign-in in the Windows shell yet, so there is nothing to fall back to.' };
  if (/session data budget/.test(l)) return { custom: 'sessionBudget' };
  if (/byedpi desync hop/.test(l)) return { key: 'byedpiHop' };
  if (/block ads/.test(l)) return { disabled: 'No ad/tracker blocklist is consumed by the Xray config builder in this build.' };
  if (/disable dns cache/.test(l)) return { disabled: 'Xray DNS cache control is not exposed by the config builder in this build.' };
  if (/dns fallback/.test(l)) return { disabled: 'No separate fallback switch is consumed: the builder already appends Local DNS as the additional resolver.' };
  if (/dedicated browser port/.test(l)) return { disabled: 'The Xray builder emits a single SOCKS inbound in this build — no separate browser port exists.' };
  if (/require a login on this device/.test(l)) return { disabled: 'Loopback SOCKS auth is not emitted by the config builder in this build.' };
  if (/update on launch|refresh subscriptions when ember opens/.test(l)) return { key: 'subscriptionAutoUpdate' };
  if (/smart groups/.test(l)) return { disabled: 'Smart groups are not implemented on Windows yet.' };
  return { disabled: 'No behaviour is bound to this switch in this build.' };
}
/* The LAN-auth toggle is DERIVED state, not a settings key: auth is
 * on exactly when a LAN username is set AND the vault holds the LAN
 * password ('lanAuthPass'). Turning it off clears both. */
async function wireLanAuthToggle(tgl) {
  const hasPass = await window.ember.secrets.has('lanAuthPass').catch(() => false);
  const on = !!(settingGet('lanAuthUser') && hasPass);
  tgl.classList.toggle('on', on);
  tgl.style.cursor = 'pointer';
  tgl.onclick = async () => {
    try {
      if (tgl.classList.contains('on')) {
        await window.ember.secrets.set('lanAuthPass', '');
        await persistSetting('lanAuthUser', '');
        tgl.classList.remove('on');
        showSvcNote('LAN proxy auth off — username and password cleared.');
        render();
      } else {
        const user = await emberPrompt('LAN proxy username:', settingGet('lanAuthUser') || '');
        if (!user || !user.trim()) return;
        const pass = await emberPrompt('LAN proxy password (stored in the encrypted vault):', '', 'password');
        if (!pass) return;
        await persistSetting('lanAuthUser', user.trim());
        await window.ember.secrets.set('lanAuthPass', pass);
        tgl.classList.add('on');
        showSvcNote('LAN proxy auth on — applies on the next V2Ray connect.');
        render();
      }
    } catch (e) { showSvcError(e); }
  };
}
/* Session data budget (UI-S-B2 task 2): the toggle is backed by
 * settings.sessionBudgetMb — ON means a budget > 0 is set (prompt
 * for MB when turning on); OFF zeroes it. The traffic loop in
 * onTrafficDelta disconnects + notes when a session passes it. */
function wireSessionBudgetToggle(tgl) {
  const on = Number(settingGet('sessionBudgetMb') || 0) > 0;
  tgl.classList.toggle('on', on);
  tgl.style.cursor = 'pointer';
  tgl.onclick = async () => {
    try {
      if (tgl.classList.contains('on')) {
        await persistSetting('sessionBudgetMb', 0);
        tgl.classList.remove('on');
        showSvcNote('Session data budget off.');
      } else {
        const v = await emberPrompt('Session data budget in MB (disconnects the V2Ray session when passed):',
          String(settingGet('sessionBudgetMb') || 500));
        if (v == null) return;
        const mb = Math.floor(Number(v));
        if (!Number.isFinite(mb) || mb <= 0) { showSvcError(new Error('Budget must be a positive number of MB.')); return; }
        await persistSetting('sessionBudgetMb', mb);
        tgl.classList.add('on');
        showSvcNote('Session data budget set to ' + mb + ' MB — applies to V2Ray sessions.');
      }
    } catch (e) { showSvcError(e); }
  };
}
/* FIX-ROUND3: a settings .srow is the natural click target, not
 * just its small right-edge control. bindSrowToggleRow makes the
 * WHOLE row act as the toggle: the row handler delegates to the
 * knob's own onclick AT CLICK TIME (custom wirings assign theirs
 * asynchronously, and the launcher-shortcuts row wraps the
 * makeToggle onclick afterwards — both must be picked up), and
 * ignores clicks that originate on the knob itself, whose own
 * handler (plus the stopPropagation in the standard wiring)
 * already fired — one click never toggles twice. Rows carrying
 * their own inner controls (inputs, selects, .fieldbox, chip
 * groups) keep those controls' clicks: no row action is bound,
 * mirroring the settings chevron loop's early-return guard. */
function bindSrowToggleRow(row, tgl) {
  if (!row || !tgl || !row.classList.contains('srow')) return;
  if (row.querySelector('input, select, textarea, .fieldbox, .pchip')) return;
  row.style.cursor = 'pointer';
  row.onclick = e => {
    if (e && e.target && e.target.closest && e.target.closest('.tgl')) return;
    if (tgl.onclick) tgl.onclick(e);
  };
}
/* FIX-ROUND3 companion for val-action rows: bind fn to BOTH the
 * .val control and its whole .srow. The val's own click stops
 * propagation and the row handler ignores val-origin clicks, so
 * one click runs fn exactly once. */
function bindSrowValRow(row, val, fn) {
  if (!row || !val || !row.classList.contains('srow')) return;
  row.style.cursor = 'pointer';
  row.onclick = e => {
    if (e && e.target && e.target.closest && e.target.closest('.val')) return;
    fn(e);
  };
}
function wireToggles() {
  document.querySelectorAll('#app .tgl').forEach(tgl => {
    // Round-1 F5 painting rule: a template-baked 'on' class must
    // NEVER survive a render. Strip first; the binding below then
    // applies the live state (key-bound toggles), the derived state
    // (custom wirings), or off+disabled (disabled-with-reason rows).
    tgl.classList.remove('on');
    const row = tgl.closest('.krow,.srow,.growhead');
    const label = row ? ((row.querySelector('.nm,.t') || {}).textContent || '') : '';
    const inEngineSection = !!(row && row.closest('.engine-section'));
    const b = toggleBinding(label.trim(), { engineSection: inEngineSection, engine: store.selectedEngine || 'mozilla' });
    if (b && b.custom === 'lanAuth') { wireLanAuthToggle(tgl); bindSrowToggleRow(row, tgl); return; }
    if (b && b.custom === 'sessionBudget') { wireSessionBudgetToggle(tgl); bindSrowToggleRow(row, tgl); return; }
    if (!b || b.disabled) {
      disableWithReason(tgl, b ? b.disabled : 'No behaviour is bound to this switch in this build.');
      return;
    }
    tgl.classList.toggle('on', !!settingGet(b.key));
    tgl.style.cursor = 'pointer';
    tgl.onclick = async e => {
      if (e && e.stopPropagation) e.stopPropagation();
      const on = !tgl.classList.contains('on');
      tgl.classList.toggle('on', on);
      await persistSetting(b.key, on);
    };
    bindSrowToggleRow(row, tgl);
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
  document.querySelectorAll('#app .krow').forEach(row => {
    const nm = (row.querySelector('.nm') || {}).textContent || '';
    const val = row.querySelector('.val');
    // No profile yet: the endpoint slot paints '—', never a
    // baked endpoint (Round-1 F5).
    if (val && /endpoint/i.test(nm)) val.innerHTML = esc(p ? (p.endpoint || '—') : '—') + ' <span class="chev">›</span>';
  });
  if (currentScreen === 'warp') paintEnginePage();
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
    } else if (currentScreen === 'mozilla' && /prepare/i.test(label)) {
      go(async () => { await mozillaPrepare(); render(); });
    } else if (currentScreen === 'mozilla') {
      disableWithReason(btn, 'Mozilla sign-in is not available in the Windows shell yet — the core ships without an account UI here.');
    } else if (currentScreen === 'lantern') {
      disableWithReason(btn, 'Private servers are not in the service Lantern API allow-list yet.');
    } else if (currentScreen === 'psiphon') {
      disableWithReason(btn, 'Psiphon region / server-entry controls are not wired to the core in this build.');
    } else if (currentScreen === 'urnetwork' && /pick country/i.test(label)) {
      go(() => { const el = document.getElementById('ur-countries-row'); if (el) el.scrollIntoView({ block: 'center' }); });
    } else {
      disableWithReason(btn, 'No action is bound to this button in this build.');
    }
  });
}

/* ---------- chevron rows (.krow .val) on engine pages ---------- */
function wireKrows() {
  if (currentScreen === 'settings' || currentScreen === 'servers' || currentScreen === 'account' || currentScreen === 'logs') return;
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
    else if ((currentScreen === 'emberwarp' || currentScreen === 'masque') && /core pick/i.test(nm)) {
      // Same pick the Settings engine section cycles
      // (settings.emberwarpEngine, read at connect time).
      go(async () => {
        const next = settingGet('emberwarpEngine') === 'aether' ? 'usque' : 'aether';
        await persistSetting('emberwarpEngine', next);
        render();
      });
    }
    else if ((currentScreen === 'emberwarp' || currentScreen === 'masque') && /protocol/i.test(nm)) {
      go(() => { location.hash = currentScreen === 'emberwarp' ? '#/masque' : '#/emberwarp'; });
    }
    else if (/core/i.test(nm)) disableWithReason(val, 'Bundled core — nothing to configure.');
    else if (currentScreen === 'mozilla' && /guardian pass/i.test(nm)) {
      // Live Guardian status from the core dashboard API (task 1).
      val.textContent = 'Check ›';
      go(async () => {
        val.textContent = 'Checking…';
        try {
          const st = await CTRLS.mozilla.guardianStatus();
          val.textContent = guardianStatusText(st) + ' ›';
        } catch (e) { val.textContent = 'Retry ›'; showSvcError(e); }
      });
    }
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

/* ---------- window controls (frameless titlebar, task 2) ---------- */
let winMaxGlyph = null;
function setMaxGlyph(maxed) {
  const b = document.getElementById('win-max');
  if (!b) return;
  if (winMaxGlyph === null) winMaxGlyph = b.innerHTML;
  b.innerHTML = maxed
    ? '<svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="3" y="1.5" width="6.5" height="6.5"/><path d="M8 3.5v6H1.5v-6"/></svg>'
    : winMaxGlyph;
  b.title = maxed ? 'Restore' : 'Maximize';
}
function wireWindowControls() {
  const min = document.getElementById('win-min');
  const max = document.getElementById('win-max');
  const close = document.getElementById('win-close');
  if (min) min.onclick = () => { if (window.ember.minimize) window.ember.minimize().catch(() => {}); };
  if (close) close.onclick = () => { if (window.ember.closeWindow) window.ember.closeWindow().catch(() => {}); };
  if (max) max.onclick = () => {
    if (!window.ember.maximizeToggle) return;
    // FIX-ADV L5: the glyph is written ONLY by the
    // 'win:maximized' event push (see boot's onMaximizedChange
    // wiring) — the toggle's invoke result must not also write
    // it: two writers race, and a stale result landing after
    // the event paints the wrong glyph.
    window.ember.maximizeToggle().catch(() => {});
  };
}

/* ---------- settings helpers ---------- */
function cardTitleOf(el) {
  const c = el.classList && el.classList.contains('setcard') ? el : (el.closest ? el.closest('.setcard') : null);
  if (!c) return '';
  const hd = c.querySelector('.hd .micro-o');
  return hd ? hd.textContent.trim() : '';
}
function rowLabelOf(row) { return ((row.querySelector('.t') || {}).textContent || '').trim(); }
function findCard(title) {
  return [...document.querySelectorAll('#app .setcard')].find(c => cardTitleOf(c) === title) || null;
}
let pendingCardScroll = null;
function scrollToCard(title) {
  const card = [...document.querySelectorAll('#app .setcard')]
    .find(c => cardTitleOf(c).toLowerCase() === String(title).toLowerCase());
  if (card) card.scrollIntoView({ block: 'start' });
}
function gotoSettingsCard(title) {
  pendingCardScroll = title;
  if (currentScreen === 'settings') { pendingCardScroll = null; scrollToCard(title); }
  else location.hash = '#/settings';
}
/* Replace a static .fieldbox div with a real input bound by label. */
function bindFieldbox(fb, get, set) {
  const input = document.createElement('input');
  input.className = 'fieldbox ember-input';
  input.value = get();
  input.spellcheck = false;
  fb.replaceWith(input);
  input.onchange = async () => { await set(input.value.trim()); };
  return input;
}
function fieldboxInput(labelRe) {
  return [...document.querySelectorAll('#app input.fieldbox')]
    .find(i => { const r = i.closest('.srow'); return r && labelRe.test(rowLabelOf(r)); }) || null;
}
/* Turn a .val span into a live toggle bound to a settings key.
 * Used where UI-T shipped a chevron row for what is really a switch
 * (RegionHop enable, DPI Lab enable). Re-renders after the flip so
 * dependent rows refresh their live/disabled state. */
function makeToggle(valEl, key) {
  const t = document.createElement('span');
  t.className = 'tgl' + (settingGet(key) ? ' on' : '');
  t.style.cursor = 'pointer';
  // FIX-ROUND3: capture the settings row BEFORE replaceWith
  // detaches valEl, then give the whole row the toggle's behaviour
  // (covers the launcher-shortcuts, quarantine, RegionHop-enable
  // and DPI-Lab-enable rows). The row handler delegates to
  // t.onclick at click time, so a later wrap of t.onclick (the
  // launcher row's applyShortcut follow-up) is honoured.
  const srow = valEl.closest ? valEl.closest('.srow') : null;
  valEl.replaceWith(t);
  t.onclick = async e => {
    if (e && e.stopPropagation) e.stopPropagation();
    const on = !t.classList.contains('on');
    t.classList.toggle('on', on);
    await persistSetting(key, on);
    render();
  };
  bindSrowToggleRow(srow, t);
  return t;
}
/* Ping sweep (UI-S-B2 task 4): every profile gains lastPingMs +
 * failStreak bookkeeping (normalizeProfile fields). A success
 * resets the streak. When settings.sweepAutoCut is on and a
 * profile's failStreak reaches settings.sweepThreshold, the
 * profile is QUARANTINED — excluded from connect attempts, badged
 * on the Servers page, restorable from its kebab menu. Profiles
 * are never deleted by a sweep. */
async function pingAllProfiles() {
  const autoCut = settingGet('sweepAutoCut') === true;
  const threshold = Math.max(1, Number(settingGet('sweepThreshold') || 3));
  let cut = 0;
  for (const p of store.profiles || []) {
    EP.normalizeProfile(p);
    if (p.lastPingMs === undefined) { p.lastPingMs = null; p.failStreak = 0; p.quarantined = false; }
    const r = await window.ember.tcpPing(p.address, p.port, 3000).catch(() => ({ ok: false }));
    p.ping = r.ok ? r.ms : null;
    p.lastPingMs = r.ok ? r.ms : null;
    if (r.ok) p.failStreak = 0;
    else {
      p.failStreak = (p.failStreak || 0) + 1;
      if (autoCut && !p.quarantined && p.failStreak >= threshold) { p.quarantined = true; cut++; }
    }
  }
  await persistProfiles();
  if (cut) showSvcNote(cut + ' config(s) quarantined by the ping sweep (fail streak ≥ ' + threshold + ') — restore them from the Servers page.');
}

/* ---------- per-engine Settings section (task 4) ----------
 * The .engine-section card's rows follow store.selectedEngine.
 * Every row is either bound to a real consumer (the same bindings
 * the engine pages use) or disabled-with-reason. No fiction. */
const ENGINE_SECTION_ROWS = {
  v2ray: [
    { t: 'UDP relay', d: 'Relay UDP through the selected server', type: 'tgl' },
    { t: 'Sniffing', d: 'http / tls · QUIC sniffing off', type: 'tgl' },
    { t: 'Sniff HTTP', d: 'Sniff HTTP host headers', type: 'tgl' },
    { t: 'Sniff TLS', d: 'Sniff TLS SNI', type: 'tgl' },
    { t: 'Sniff QUIC', d: 'Sniff QUIC — off by default', type: 'tgl' },
    { t: 'Block QUIC', d: 'Block all UDP/443 so apps fall back to TCP', type: 'tgl' },
    { t: 'Tunnel bridge', d: 'Hev (default) or legacy tunlink — the 2155 A/B switch', type: 'val', val: 'Hev ›', act: 'dis', reason: 'The Windows TUN is owned by the Ember service (ember-tun-bridge); the Android Hev/tunlink A/B switch does not exist on Windows.' },
  ],
  mozilla: [
    { t: 'Core', d: 'Bundled Mozilla core (firefox-vpn-core)', type: 'val', val: 'Bundled ›', act: 'dis', reason: 'Bundled core — nothing to configure.' },
    { t: 'Guardian pass', d: 'Guardian pass status from the running core (dashboard API)', type: 'val', val: 'Check ›', act: 'guardianStatus' },
    { t: 'Prepare / pass refresh', d: 'Fetch a fresh Guardian pass before it expires (core dashboard API)', type: 'val', val: 'Prepare ›', act: 'mozillaPrepare' },
    { t: 'Sign-in & account', d: 'Mozilla account for this engine', type: 'val', val: '›', act: 'dis', reason: 'Mozilla sign-in is not available in the Windows shell yet — the core ships without an account UI here.' },
  ],
  lantern: [
    { t: 'Smart routing', d: 'Route only some traffic via the private server', type: 'tgl' },
    { t: 'Server selection', d: 'Which Lantern server carries the session — cycles the daemon list', type: 'val', val: 'Cycle ›', act: 'lanternServer' },
    { t: 'Private servers', d: 'Your own Lantern server', type: 'val', val: '›', act: 'dis', reason: 'Private servers are not in the service Lantern API allow-list yet.' },
  ],
  wireguard: [
    { t: 'Selected tunnel', d: 'The WireGuard profile used on connect', type: 'val', val: 'Servers ›', act: 'servers' },
    { t: 'DNS', d: 'Resolver for the tunnel', type: 'val', val: 'From config ›', act: 'dis', reason: 'DNS is taken from the tunnel config.' },
    { t: 'Kill switch', d: 'Block traffic if the tunnel drops', type: 'tgl' },
  ],
  warp: [
    { t: 'Endpoint', d: 'Cloudflare endpoint for the WARP tunnel', type: 'val', val: 'Cycle ›', act: 'warpEndpoint' },
    { t: 'Register', d: 'Mint a fresh WARP identity with Cloudflare', type: 'val', val: 'Register ›', act: 'warpRegister' },
    { t: 'Mode', d: 'Plain WARP only on Windows', type: 'val', val: 'WARP ›', act: 'dis', reason: 'Only plain WARP exists on Windows; the other modes live in Android Settings.' },
  ],
  psiphon: [
    { t: 'Region', d: 'Egress region', type: 'val', val: 'Auto ›', act: 'dis', reason: 'Psiphon picks its region and egress itself; nothing to configure here.' },
    { t: 'Egress', d: 'Server entry selection', type: 'val', val: 'Auto ›', act: 'dis', reason: 'Psiphon picks its region and egress itself; nothing to configure here.' },
  ],
  openvpn: [
    { t: 'Import profile', d: 'Import a .ovpn file', type: 'val', val: 'Import ›', act: 'ovpnImport' },
    { t: 'Auth', d: 'Username / password for the selected profile', type: 'val', val: '›', act: 'dis', reason: 'OpenVPN credential entry is not part of this build; auth requests surface in the engine state.' },
  ],
  emberwarp: [
    { t: 'Core pick', d: 'usque (primary) or aether (fallback) — read at connect time', type: 'val', val: '', act: 'corePick' },
    { t: 'Protocol', d: 'EmberWarp and MASQUE are the two sides of one engine', type: 'val', val: 'MASQUE ›', act: 'protoSwap' },
    { t: 'Kill switch', d: 'Block traffic if the tunnel drops', type: 'tgl' },
  ],
  masque: [
    { t: 'Core pick', d: 'usque (primary) or aether (fallback) — read at connect time', type: 'val', val: '', act: 'corePick' },
    { t: 'Protocol', d: 'EmberWarp and MASQUE are the two sides of one engine', type: 'val', val: 'EmberWarp ›', act: 'protoSwap' },
    { t: 'Kill switch', d: 'Block traffic if the tunnel drops', type: 'tgl' },
  ],
  urnetwork: [
    { t: 'Providing', d: 'Never become an exit node for strangers', type: 'tgl' },
    { t: 'Managed profiles', d: 'URnetwork proxies live with the other configs', type: 'val', val: 'Servers ›', act: 'servers' },
    { t: 'Accounts', d: 'API keys, stored only in the encrypted vault', type: 'val', val: 'Open ›', act: 'urPage' },
  ],
};
function buildEngineSection() {
  const sec = document.querySelector('#app .engine-section');
  if (!sec) return;
  const eng = store.selectedEngine || 'mozilla';
  const sub = document.querySelector('#app .hero .sub b');
  if (sub) sub.textContent = ENGINE_LABEL[eng] || eng;
  const rows = ENGINE_SECTION_ROWS[eng];
  if (!rows) return;
  sec.innerHTML = '<div class="hd"><span class="micro-o">Engine section · ' + esc(ENGINE_LABEL[eng] || eng) + '</span></div>' +
    rows.map(r => '<div class="srow"><div><div class="t">' + esc(r.t) + '</div><div class="d">' + esc(r.d) + '</div></div>' +
      (r.type === 'tgl'
        ? '<span class="tgl"></span>'
        : '<span class="val" data-act="' + esc(r.act || '') + '"' + (r.reason ? ' data-reason="' + esc(r.reason) + '"' : '') + '>' + esc(r.val || '›') + '</span>') +
      '</div>').join('');
}
/* Mozilla Guardian helpers (UI-S-B2 task 1): status + prepare go
 * through controllers.mozilla → the core dashboard API. Every
 * failure state is shown honestly: core not running, the 401
 * dashboard-login caveat, or the API's own error text. */
function guardianStatusText(st) {
  if (!st) return 'No status from the core.';
  const parts = [];
  if (st.pass_expires_at) parts.push('pass expires ' + new Date(st.pass_expires_at * 1000).toLocaleString());
  else parts.push('no stored pass');
  const acct = st.active_account && (st.active_account.email || st.active_account.name);
  if (acct) parts.push('account ' + acct);
  const phase = st.state && (st.state.phase || st.state.code);
  if (phase) parts.push('proxy ' + phase);
  const pass = st.proxy && st.proxy.pass;
  if (pass && typeof pass === 'object') {
    const usage = pass.usage || pass.requests || pass.count;
    if (usage !== undefined) parts.push('Guardian usage ' + usage);
  }
  return parts.join(' · ');
}
async function refreshGuardianRow(val, row) {
  const dEl = row ? row.querySelector('.d') : null;
  try {
    const st = await CTRLS.mozilla.guardianStatus();
    if (dEl) dEl.textContent = guardianStatusText(st);
    if (val) val.textContent = 'Refresh ›';
    return st;
  } catch (e) {
    if (dEl) dEl.textContent = e.message;
    if (val) val.textContent = 'Retry ›';
    return null;
  }
}
async function mozillaPrepare() {
  // Donor egress for the bootstrap prepare: the live V2Ray SOCKS
  // when V2Ray is connected (the core's intended flow).
  const donor = isConnectedWord(engineState.get('v2ray')) ? '127.0.0.1:10808' : null;
  const r = await CTRLS.mozilla.prepare(donor);
  showSvcNote('Guardian pass prepared' + (r && r.pass_expires_at
    ? ' — expires ' + new Date(r.pass_expires_at * 1000).toLocaleString() : '') + '.');
  return r;
}
function wireEngineSection() {
  const eng = store.selectedEngine || 'mozilla';
  document.querySelectorAll('#app .engine-section .srow').forEach(row => {
    const val = row.querySelector('.val');
    if (!val || val.querySelector('.tgl')) return;
    const act = val.dataset.act || '';
    const go = fn => { val.style.cursor = 'pointer'; val.onclick = () => { Promise.resolve().then(fn).catch(e => showSvcError(e)); }; };
    if (act === 'dis') disableWithReason(val, val.dataset.reason || 'Nothing to configure here in this build.');
    else if (act === 'servers') go(() => { location.hash = '#/servers'; });
    else if (act === 'urPage') go(() => { location.hash = '#/urnetwork'; });
    else if (act === 'lanternServer') go(() => cycleLanternServer(val));
    else if (act === 'warpEndpoint') go(cycleWarpEndpoint);
    else if (act === 'warpRegister') go(async () => { await CTRLS.warp.register(true); await refreshWarpDisplay(); showSvcNote('WARP identity registered with Cloudflare.'); });
    else if (act === 'ovpnImport') go(() => pickImportFile());
    else if (act === 'protoSwap') go(() => { location.hash = eng === 'emberwarp' ? '#/masque' : '#/emberwarp'; });
    else if (act === 'guardianStatus') go(() => refreshGuardianRow(val, row));
    else if (act === 'mozillaPrepare') go(async () => {
      await mozillaPrepare();
      await refreshGuardianRow(val, row);
    });
    else if (act === 'corePick') {
      const paint = () => { val.textContent = (settingGet('emberwarpEngine') || 'usque') + ' ›'; };
      paint();
      go(async () => {
        const next = settingGet('emberwarpEngine') === 'aether' ? 'usque' : 'aether';
        await persistSetting('emberwarpEngine', next);
        paint();
        showSvcNote('EmberWarp core: ' + next + ' — applies on the next connect.');
      });
    }
    else disableWithReason(val, 'Nothing to configure here in this build.');
  });
}

/* ---------- app lock PIN (task 5) ----------
 * The PIN itself is never stored: its SHA-256 hex digest lives in
 * the safeStorage vault under the secret key 'appLockPinHash'
 * (window.ember.secrets). settings.appLock (bool) arms the lock. */
const APP_LOCK_PIN_KEY = 'appLockPinHash';
async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(text)));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}
async function setPinFlow() {
  const has = await window.ember.secrets.has(APP_LOCK_PIN_KEY).catch(() => false);
  if (has) {
    const cur = await emberPrompt('Current PIN:', '', 'password');
    if (cur == null) return false;
    if (await sha256Hex(cur) !== await window.ember.secrets.get(APP_LOCK_PIN_KEY)) {
      showSvcError(new Error('Wrong current PIN.')); return false;
    }
  }
  const p1 = await emberPrompt('New PIN (at least 4 characters):', '', 'password');
  if (!p1) return false;
  if (p1.length < 4) { showSvcError(new Error('PIN must be at least 4 characters.')); return false; }
  const p2 = await emberPrompt('Confirm the new PIN:', '', 'password');
  if (p2 !== p1) { showSvcError(new Error('PINs do not match.')); return false; }
  await window.ember.secrets.set(APP_LOCK_PIN_KEY, await sha256Hex(p1));
  showSvcNote('App-lock PIN set.');
  return true;
}
async function wireAppLockRows() {
  const card = findCard('Privacy & sync');
  if (!card) return;
  const row = [...card.querySelectorAll('.srow')].find(r => /app lock/i.test(rowLabelOf(r)));
  if (!row) return;
  const val = row.querySelector('.val');
  const paint = async () => {
    const has = await window.ember.secrets.has(APP_LOCK_PIN_KEY).catch(() => false);
    if (val) val.textContent = settingGet('appLock') && has ? 'On ›' : (has ? 'Off ›' : 'Set PIN ›');
    const setLbl = document.getElementById('pin-set-val');
    if (setLbl) setLbl.textContent = has ? 'Change ›' : 'Set ›';
  };
  if (val) {
    val.style.cursor = 'pointer';
    val.onclick = async e => {
      if (e && e.stopPropagation) e.stopPropagation();
      try {
        const has = await window.ember.secrets.has(APP_LOCK_PIN_KEY).catch(() => false);
        if (!settingGet('appLock')) {
          if (!has && !(await setPinFlow())) { await paint(); return; }
          await persistSetting('appLock', true);
          showSvcNote('App lock on — Ember will ask for the PIN when it opens.');
        } else {
          const pin = await emberPrompt('Enter your PIN to turn off the app lock:', '', 'password');
          if (pin == null) return;
          if (await sha256Hex(pin) !== await window.ember.secrets.get(APP_LOCK_PIN_KEY)) {
            showSvcError(new Error('Wrong PIN.')); return;
          }
          await persistSetting('appLock', false);
          showSvcNote('App lock off.');
        }
      } catch (e) { showSvcError(e); }
      await paint();
    };
    // FIX-ROUND3: the whole app-lock row runs the same flow.
    bindSrowValRow(row, val, () => { if (val.onclick) val.onclick(); });
  }
  if (!document.getElementById('applock-pin-rows')) {
    const wrap = document.createElement('div');
    wrap.id = 'applock-pin-rows';
    wrap.innerHTML =
      '<div class="srow"><div><div class="t">Lock PIN</div><div class="d">Set or change the app-lock PIN — only its SHA-256 hash is kept, in the vault</div></div><span class="val" id="pin-set-val">Set ›</span></div>' +
      '<div class="srow"><div><div class="t">Remove PIN</div><div class="d">Remove the PIN and turn the app lock off</div></div><span class="val" id="pin-remove-val">›</span></div>' +
      '<div class="srow"><div><div class="t">Fingerprint / face unlock</div><div class="d">Biometric unlock</div></div><span class="val" id="pin-bio-val">›</span></div>';
    row.after(wrap);
    const setVal = wrap.querySelector('#pin-set-val');
    setVal.style.cursor = 'pointer';
    setVal.onclick = async e => { if (e && e.stopPropagation) e.stopPropagation(); if (await setPinFlow()) render(); };
    // FIX-ROUND3: whole-row clicks for the PIN rows too.
    bindSrowValRow(setVal.closest('.srow'), setVal, () => { if (setVal.onclick) setVal.onclick(); });
    const remVal = wrap.querySelector('#pin-remove-val');
    remVal.style.cursor = 'pointer';
    remVal.onclick = async e => {
      if (e && e.stopPropagation) e.stopPropagation();
      try {
        const has = await window.ember.secrets.has(APP_LOCK_PIN_KEY).catch(() => false);
        if (!has) { showSvcNote('No app-lock PIN is set.'); return; }
        const pin = await emberPrompt('Enter your PIN to remove it:', '', 'password');
        if (pin == null) return;
        if (await sha256Hex(pin) !== await window.ember.secrets.get(APP_LOCK_PIN_KEY)) {
          showSvcError(new Error('Wrong PIN.')); return;
        }
        await window.ember.secrets.set(APP_LOCK_PIN_KEY, '');
        await persistSetting('appLock', false);
        showSvcNote('App-lock PIN removed; app lock off.');
        render();
      } catch (e) { showSvcError(e); }
    };
    bindSrowValRow(remVal.closest('.srow'), remVal, () => { if (remVal.onclick) remVal.onclick(); });
    disableWithReason(wrap.querySelector('#pin-bio-val'),
      'Windows Hello biometrics are not wired in this shell — the PIN is the unlock method here.');
  }
  await paint();
}
/* Boot gate: when appLock is on AND a PIN exists, block the UI
 * behind a lock overlay until the correct PIN is entered. */
async function appLockGate() {
  if (meta.shoot) return; // screenshot mode never locks
  if (!settingGet('appLock')) return;
  const has = await window.ember.secrets.has(APP_LOCK_PIN_KEY).catch(() => false);
  if (!has) return;
  const hash = await window.ember.secrets.get(APP_LOCK_PIN_KEY).catch(() => null);
  if (!hash) return;
  await new Promise(resolve => {
    const wrap = document.createElement('div');
    wrap.className = 'ember-dialog-wrap';
    wrap.innerHTML = '<div class="ember-dialog">' +
      '<div class="ember-dialog-msg">Ember is locked — enter your PIN.</div>' +
      '<input class="ember-dialog-input" type="password" id="lock-pin">' +
      '<div class="ember-dialog-msg" id="lock-err" style="min-height:18px"></div>' +
      '<div class="ember-dialog-row"><button class="ember-dialog-btn ok" id="lock-ok">Unlock</button></div></div>';
    document.body.appendChild(wrap);
    const input = wrap.querySelector('#lock-pin');
    input.focus();
    const tryUnlock = async () => {
      if (await sha256Hex(input.value) === hash) { wrap.remove(); resolve(); }
      else { wrap.querySelector('#lock-err').textContent = 'Wrong PIN — try again.'; input.select(); }
    };
    wrap.querySelector('#lock-ok').onclick = tryUnlock;
    input.addEventListener('keydown', e => { if (e.key === 'Enter') tryUnlock(); });
  });
}

/* ---------- backup / restore (task 6) ---------- */
async function exportBackup() {
  const r = await window.ember.backupExport();
  if (!r || r.cancelled) return;
  if (!r.ok) throw new Error(r.error || 'Backup export failed.');
  // FIX-ADV M1 — honesty, both directions: the file is a
  // PLAIN-TEXT credential dump (profile UUIDs/passwords/keys,
  // WireGuard private keys, OpenVPN key material, subscription
  // URLs), and it silently OMITS the vault-held secrets, so a
  // restore is not complete without re-entering them.
  showSvcNote('Backup exported to ' + r.path + '. WARNING: this file contains profile credentials in PLAIN TEXT — guard it like a key file. ' +
    'Vault-held items are NOT included (URnetwork API keys, the LAN-sharing password, the app-lock PIN) — they must be re-entered after a restore.');
}
/* FIX-ADV M2: the canonical top-level store keys a backup may
 * carry — main.js DEFAULT_STATE's keys (version, selectedEngine,
 * profiles, subscriptions, selectedProfileId, settings,
 * engineSettings, urnetworkAccounts, lantern, warpProfile,
 * lastDailyReportDate) plus 'groups' (profile-group bookkeeping
 * the renderer keeps alongside them). Anything else in an import
 * file is dropped and counted, never transplanted. */
const BACKUP_STORE_KEYS = ['version', 'selectedEngine', 'profiles', 'subscriptions',
  'selectedProfileId', 'settings', 'engineSettings', 'urnetworkAccounts', 'lantern',
  'warpProfile', 'lastDailyReportDate', 'groups'];
/* A profile entry is importable only if it is a plain object
 * carrying at least one identity the app can act on (a protocol,
 * a source link, or inline config text); survivors are passed
 * through EmberProfiles.normalizeProfile like every other
 * profile the store ever holds. */
function backupProfileValid(p) {
  if (!p || typeof p !== 'object' || Array.isArray(p)) return false;
  return (typeof p.protocol === 'string' && !!p.protocol)
    || (typeof p.link === 'string' && !!p.link)
    || (typeof p.confText === 'string' && !!p.confText)
    || (typeof p.configText === 'string' && !!p.configText);
}
async function importBackup() {
  const r = await window.ember.backupImport();
  if (!r || r.cancelled) return;
  if (!r.ok) throw new Error(r.error || 'Backup import failed.');
  const d = r.data;
  if (!d || typeof d !== 'object' || Array.isArray(d) ||
      !d.settings || typeof d.settings !== 'object' || Array.isArray(d.settings) ||
      !Array.isArray(d.profiles)) {
    throw new Error('That file is not an Ember backup — it must carry a settings object and a profiles list.');
  }
  // Validate BEFORE anything is transplanted (FIX-ADV M2):
  // unknown top-level keys dropped, profiles normalised with
  // invalid entries dropped, subscription entries required to
  // be objects with an http(s) url (their urls become fetch
  // targets for the boot-time auto-refresh).
  let dropped = 0;
  const clean = {};
  for (const k of Object.keys(d)) {
    if (!BACKUP_STORE_KEYS.includes(k)) { dropped++; continue; }
    clean[k] = d[k];
  }
  const profiles = [];
  for (const p of d.profiles) {
    if (backupProfileValid(p)) profiles.push(EP.normalizeProfile(p));
    else dropped++;
  }
  clean.profiles = profiles;
  if (clean.subscriptions !== undefined) {
    if (!Array.isArray(clean.subscriptions)) { dropped++; delete clean.subscriptions; }
    else {
      const subs = [];
      for (const s of clean.subscriptions) {
        if (s && typeof s === 'object' && !Array.isArray(s) &&
            typeof s.url === 'string' && /^https?:\/\//i.test(s.url)) subs.push(s);
        else dropped++;
      }
      clean.subscriptions = subs;
    }
  }
  if (!(await emberConfirm('Replace ALL Ember data (settings, profiles, subscriptions) with this backup?'))) return;
  for (const k of Object.keys(clean)) await window.ember.store.set(k, clean[k]);
  store = await window.ember.store.get();
  window.__emberSettings = store.settings || {};
  render();
  showSvcNote('Backup imported — ' + profiles.length + ' profile(s) imported, ' + dropped + ' invalid entr' + (dropped === 1 ? 'y' : 'ies') + ' dropped.');
}

/* ---------- RegionHop card (task 7) ---------- */
async function wireRegionHopCard(card) {
  const rows = [...card.querySelectorAll('.srow')];
  const first = rows.find(r => rowLabelOf(r) === 'RegionHop');
  if (first) { const val = first.querySelector('.val'); if (val) makeToggle(val, 'regionHopEnabled'); }
  const statusRow = document.createElement('div');
  statusRow.className = 'srow';
  statusRow.innerHTML = '<div><div class="t">Relay profiles</div><div class="d">Checking RegionHop defaults…</div></div>' +
    '<span class="val"><button class="chipbtn o" data-action="rh-create">Create relay profiles</button></span>';
  card.appendChild(statusRow);
  const dEl = statusRow.querySelector('.d');
  const btn = statusRow.querySelector('[data-action="rh-create"]');
  const st = await REGIONHOP.status().catch(e => ({ available: false, enabled: false, locations: [], reason: String(e.message || e) }));
  const panelRow = rows.find(r => rowLabelOf(r) === 'Panel URL');
  if (panelRow) {
    const v = panelRow.querySelector('.val');
    if (v) disableWithReason(v, 'The panel URL ships in the build-time RegionHop defaults and is not editable here.');
  }
  const locRow = rows.find(r => rowLabelOf(r) === 'Locations');
  if (locRow) {
    const v = locRow.querySelector('.val');
    if (v) {
      v.textContent = st.available ? st.locations.length + ' location(s) ›' : '—';
      disableWithReason(v, 'Locations come from the build-time RegionHop defaults; nothing to edit here.');
    }
  }
  if (st.available) {
    dEl.textContent = 'Available — exits: ' + st.locations.map(l => String(l.name).toUpperCase()).join(', ') +
      (st.enabled ? '' : ' · RegionHop is off — turn it on above to create profiles.');
  } else {
    dEl.textContent = st.reason || 'RegionHop is unavailable in this build.';
  }
  if (!st.available) disableWithReason(btn, st.reason || 'RegionHop is unavailable in this build.');
  else if (!st.enabled) disableWithReason(btn, 'RegionHop is off — turn it on above first.');
  else btn.onclick = async () => {
    try {
      const ps = await REGIONHOP.makeProfiles();
      const fresh = ps.filter(p => !(store.profiles || []).some(x => x.id === p.id));
      if (fresh.length) await addProfiles(fresh);
      showSvcNote(fresh.length
        ? fresh.length + ' RegionHop relay profile(s) added — find them on the Servers page.'
        : 'RegionHop relay profiles already exist — see Servers.');
    } catch (e) { showSvcError(e); }
  };
}

/* ---------- DPI Lab card (task 7) ---------- */
function wireDpiLabCard(card) {
  const rows = [...card.querySelectorAll('.srow')];
  const first = rows.find(r => rowLabelOf(r) === 'DPI Strategy Lab');
  if (first) { const val = first.querySelector('.val'); if (val) makeToggle(val, 'dpiLabEnabled'); }
  rows.forEach(r => {
    if (/senpai/i.test(rowLabelOf(r))) {
      const v = r.querySelector('.val');
      if (v) disableWithReason(v, 'The Senpai scanner does not ship on Windows.');
    }
  });
  const wrap = document.createElement('div');
  wrap.className = 'srow';
  wrap.style.display = 'block';
  wrap.innerHTML = '<div class="t">Strategy</div>' +
    '<div class="pchips" id="dpi-strats">' +
    ZAPRET_STRATEGIES.map((s, i) => '<span class="pchip' + (i === 0 ? ' sel' : '') + '">' + esc(s.label) + '</span>').join('') +
    '</div><div class="d" id="dpi-state" style="margin-top:6px"></div>' +
    '<div style="margin-top:8px"><button class="chipbtn o" data-action="dpi-toggle">' + (BYEDPI.running ? 'Stop' : 'Start') + '</button></div>';
  card.appendChild(wrap);
  let selected = (ZAPRET_STRATEGIES[0] || {}).id || null;
  wireChipGroup(wrap.querySelector('#dpi-strats'), name => {
    const s = ZAPRET_STRATEGIES.find(x => x.label === name);
    if (s) selected = s.id;
  });
  const stateEl = wrap.querySelector('#dpi-state');
  const btn = wrap.querySelector('[data-action="dpi-toggle"]');
  const enabled = settingGet('dpiLabEnabled') === true;
  stateEl.textContent = BYEDPI.running
    ? 'Running — strategy ' + (BYEDPI.strategy || '') + ' · ciadpi SOCKS on 127.0.0.1:20864 (no TUN; point an app at it).'
    : (enabled ? 'Stopped. Start runs ciadpi with the chosen desync strategy.'
               : 'The DPI Lab is off — turn it on above first.');
  if (!enabled && !BYEDPI.running) {
    disableWithReason(btn, 'The DPI Lab is off — turn it on above first (settings.dpiLabEnabled).');
  } else {
    btn.onclick = async () => {
      try {
        await BYEDPI.toggle(selected);
        showSvcNote(BYEDPI.running ? 'DPI Lab running — ciadpi SOCKS on 127.0.0.1:20864.' : 'DPI Lab stopped.');
      } catch (e) { showSvcError(e); }
      render();
    };
  }
  rows.forEach(r => {
    if (/open the strategy lab/i.test(rowLabelOf(r))) {
      const v = r.querySelector('.val');
      if (v) {
        v.style.cursor = 'pointer';
        v.onclick = e => { if (e && e.stopPropagation) e.stopPropagation(); wrap.scrollIntoView({ block: 'center' }); };
        // FIX-ROUND3: the whole row scrolls to the lab, not just .val.
        bindSrowValRow(r, v, () => wrap.scrollIntoView({ block: 'center' }));
      }
    }
  });
}

/* ---------- Logs page (task 8) ---------- */
let logsSource = 'all';
function logsHTML() {
  const rail = extractRail(templates.settings).replace('navrow on', 'navrow');
  return `<div class="stage"><div class="map"><img src="../assets/map_backdrop_home.webp" alt=""></div><div class="faint"></div>
  ${TITLEBAR_HTML}
  ${rail}
  <div class="content"><div class="phead"><div><div class="micro-o">Ralysnd Ember</div>
  <div class="hero" style="margin-top:10px"><div class="word" style="font-size:40px">Logs</div>
  <div class="sub">What the Ember service has sent this session — engine output, exits and service state. Back via Settings in the rail.</div></div></div></div>
  <div class="rows">
    <div class="krow"><div class="t"><div class="nm">Source</div><div class="ds">Log sources received from the service event stream.</div></div>
    <div class="val"><span class="pchips" id="logs-srcs"></span></div></div>
    <div class="krow"><div class="t"><div class="nm">Lines</div><div class="ds" id="logs-count">—</div></div>
    <div class="val"><button class="chipbtn" data-action="logs-clear">Clear</button> <button class="chipbtn o" data-action="logs-refresh">Refresh</button></div></div>
  </div>
  <div class="fieldbox" id="logs-view" style="white-space:pre-wrap;overflow:auto;max-height:400px;text-align:left;font-size:11.5px;line-height:1.5"></div>
  </div></div>`;
}
function fillLogs() {
  const view = document.getElementById('logs-view');
  if (!view) return;
  const lines = LOGS.lines(logsSource === 'all' ? null : logsSource);
  const count = document.getElementById('logs-count');
  if (count) count.textContent = lines.length + ' line(s)' + (logsSource === 'all' ? ' across all sources' : ' from ' + logsSource);
  view.textContent = lines.length
    ? lines.map(e => (logsSource === 'all' && e.key ? '[' + e.key + '] ' : '') +
        new Date(e.ts).toLocaleTimeString() + '  ' + e.line).join('\n')
    : 'No log lines received yet — connect an engine and they will appear here.';
  view.scrollTop = view.scrollHeight; // auto-scrollback: newest lines in view
}
function wireLogsPage() {
  const srcs = document.getElementById('logs-srcs');
  if (!srcs) return;
  const keys = ['all', ...LOGS.keys()];
  if (!keys.includes(logsSource)) logsSource = 'all';
  srcs.innerHTML = keys.map(k => '<span class="pchip' + (k === logsSource ? ' sel' : '') + '">' + esc(k) + '</span>').join('');
  wireChipGroup(srcs, name => { logsSource = name; fillLogs(); });
  const refresh = document.querySelector('[data-action="logs-refresh"]');
  if (refresh) refresh.onclick = () => fillLogs();
  const clear = document.querySelector('[data-action="logs-clear"]');
  if (clear) clear.onclick = () => { LOGS.clear(logsSource === 'all' ? undefined : logsSource); render(); };
  fillLogs();
}

/* ---------- Settings page ---------- */
const DNS_PRESET_URLS = {
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
  if (!container) return;
  container.querySelectorAll('.pchip').forEach(chip => {
    chip.style.cursor = 'pointer';
    chip.onclick = () => { selectChip(container, chip); onPick(chip.textContent.trim()); };
  });
}
function dnsPresetGroup() {
  return [...document.querySelectorAll('#app .pchips')]
    .find(g => [...g.querySelectorAll('.pchip')].some(c => c.textContent.trim() === 'Shecan')) || null;
}
function markDnsPresetSelection() {
  const group = dnsPresetGroup();
  if (!group) return;
  const preset = settingGet('dnsPreset');
  const remote = settingGet('remoteDns');
  let matched = false;
  group.querySelectorAll('.pchip').forEach(c => {
    const name = c.textContent.trim();
    let on = false;
    if (name === 'Global') on = preset === 'google';
    else if (name !== 'Custom' && DNS_PRESET_URLS[name]) on = preset === 'custom' && remote === DNS_PRESET_URLS[name];
    if (on) matched = true;
    c.classList.toggle('sel', on); c.classList.remove('fill');
  });
  const custom = [...group.querySelectorAll('.pchip')].find(c => c.textContent.trim() === 'Custom');
  if (custom) custom.classList.toggle('sel', preset === 'custom' && !matched);
}
function markLocalDnsSelection() {
  const group = [...document.querySelectorAll('#app .pchips')]
    .find(g => { const r = g.closest('.srow'); return r && /local dns/i.test(rowLabelOf(r)); });
  if (!group) return;
  const cur = settingGet('localDns');
  group.querySelectorAll('.pchip').forEach(c => {
    const n = c.textContent.trim();
    const on = (n === 'System' && !cur) || (n === 'Google' && cur === '8.8.8.8') || (n === 'Cloudflare' && cur === '1.1.1.1');
    c.classList.toggle('sel', on); c.classList.remove('fill');
  });
}
function wireSettingsPage() {
  wireEngineSection();
  /* --- fieldboxes, bound by their row labels (task 3: not just the first) --- */
  document.querySelectorAll('#app .fieldbox').forEach(fb => {
    const row = fb.closest('.srow');
    const label = row ? rowLabelOf(row) : '';
    if (/remote dns/i.test(label)) {
      bindFieldbox(fb, () => settingGet('remoteDns'), async v => {
        await persistSetting('remoteDns', v);
        if (settingGet('dnsPreset') !== 'custom') await persistSetting('dnsPreset', 'custom');
        markDnsPresetSelection();
      });
    } else if (/local dns/i.test(label)) {
      bindFieldbox(fb, () => settingGet('localDns'), async v => {
        await persistSetting('localDns', v);
        markLocalDnsSelection();
      });
    } else if (/fallback dns/i.test(label)) {
      disableWithReason(fb, 'Not consumed separately: the config builder already appends Local DNS as the additional resolver.');
    }
  });
  /* --- chip groups --- */
  document.querySelectorAll('#app .pchips').forEach(group => {
    if (group.closest('.engine-section')) return;
    const row = group.closest('.srow');
    const rowLabel = row ? rowLabelOf(row) : '';
    const names = [...group.querySelectorAll('.pchip')].map(c => c.textContent.trim()).filter(Boolean);
    if (names.includes('Shecan')) {
      wireChipGroup(group, async name => {
        if (name === 'Custom') {
          await persistSetting('dnsPreset', 'custom');
          const i = fieldboxInput(/remote dns/i);
          if (i) i.focus();
          markDnsPresetSelection();
          return;
        }
        if (name === 'Global') {
          await persistSetting('dnsPreset', 'google');
          await persistSetting('remoteDns', DNS_PRESET_URLS.Global);
        } else if (DNS_PRESET_URLS[name]) {
          // The Iranian catalogue resolves through dnsPreset:'custom'
          // + remoteDns (profiles.js bakes in only google/cloudflare).
          await persistSetting('dnsPreset', 'custom');
          await persistSetting('remoteDns', DNS_PRESET_URLS[name]);
        }
        const i = fieldboxInput(/remote dns/i);
        if (i) i.value = settingGet('remoteDns');
        markDnsPresetSelection();
      });
      markDnsPresetSelection();
    } else if (/transport/i.test(rowLabel)) {
      const cur = settingGet('dnsTransport');
      group.querySelectorAll('.pchip').forEach(chip => {
        const n = chip.textContent.trim();
        chip.classList.toggle('sel', (n === 'DoH' && cur === 'doh') || (n === 'TCP' && (cur === 'tcp' || cur === 'udp')));
        chip.classList.remove('fill');
        if (n === 'DoH' || n === 'TCP') {
          chip.style.cursor = 'pointer';
          chip.onclick = async () => { selectChip(group, chip); await persistSetting('dnsTransport', n === 'DoH' ? 'doh' : 'tcp'); };
        } else {
          disableWithReason(chip, n + ' is not a transport the DNS resolver can emit — profiles.js resolveDnsServers supports DoH, UDP and TCP only.');
        }
      });
    } else if (/local dns/i.test(rowLabel)) {
      wireChipGroup(group, async name => {
        const v = name === 'Google' ? '8.8.8.8' : name === 'Cloudflare' ? '1.1.1.1' : '';
        await persistSetting('localDns', v);
        const i = fieldboxInput(/local dns/i);
        if (i) i.value = v;
        markLocalDnsSelection();
      });
      markLocalDnsSelection();
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
  /* --- chevron .val rows, per card --- */
  document.querySelectorAll('#app .srow').forEach(row => {
    if (row.closest('.engine-section')) return; // wired by wireEngineSection
    const card = cardTitleOf(row);
    if (card === 'RegionHop' || card === 'DPI Lab' || card === 'Logs') return; // dedicated wiring below
    const label = rowLabelOf(row);
    const l = label.toLowerCase();
    const val = row.querySelector('.val');
    if (!val || val.querySelector('.tgl') || val.querySelector('.pchip') || val.querySelector('.fieldbox') || val.querySelector('input')) return;
    const dis = r => disableWithReason(val, r);
    // FIX-ROUND3: go() binds BOTH the .val control and the whole
    // row to fn — the row is the natural click target. The val's
    // click stops propagation and the row handler ignores
    // val-origin clicks, so fn runs exactly once per click.
    // dis() rows deliberately get NO row action (their .val
    // carries the reason tooltip only).
    const go = fn => {
      val.style.cursor = 'pointer'; row.style.cursor = 'pointer';
      const run = () => { Promise.resolve().then(fn).catch(e => showSvcError(e)); };
      val.onclick = e => { if (e && e.stopPropagation) e.stopPropagation(); run(); };
      row.onclick = e => {
        if (e && e.target && e.target.closest && e.target.closest('.val')) return;
        run();
      };
    };
    if (/language/.test(l)) dis('English only in this build — the whole app is English by the owner\u2019s ruling.');
    else if (/check for updates/.test(l)) go(checkUpdate);
    else if (/update channel/.test(l)) dis('Only the stable channel exists: the updater reads the latest GitHub release.');
    else if (/per-app routing/.test(l)) dis('Android-only concept — no Windows equivalent, as the row itself says.');
    else if (/launcher shortcuts/.test(l)) {
      // UI-S-B2 task 9: the global shortcut toggle — main registers
      // Ctrl+Alt+E (applyShortcut runs on every settings save too).
      const t = makeToggle(val, 'globalShortcut');
      const orig = t.onclick;
      // FIX-ROUND3: makeToggle already bound the whole row to
      // t.onclick AT CLICK TIME, so this wrap (with the
      // applyShortcut follow-up) is what row clicks run too.
      t.onclick = async () => { await orig(); if (window.ember.applyShortcut) await window.ember.applyShortcut(settingGet('globalShortcut') === true).catch(() => {}); };
    }
    else if (/tunnel mtu/.test(l)) dis('No MTU consumer exists: Xray has no MTU knob and the service tun.start contract carries no MTU field.');
    else if (/fallback chain/.test(l)) dis('No fallback-chain engine exists on Windows yet.');
    else if (/custom chains/.test(l)) dis('Chained connects are not implemented on Windows yet.');
    else if (/leak test/.test(l)) dis('The leak test is not implemented on Windows yet — no probe is wired.');
    else if (/filtering probe/.test(l)) dis('The filtering probe is not implemented on Windows yet.');
    else if (/logs/.test(l) && card === 'Automation & diagnostics') go(() => { location.hash = '#/logs'; });
    else if (/app lock/.test(l)) { /* wired by wireAppLockRows below */ }
    else if (/sync via github/.test(l)) dis('GitHub sync is not implemented on Windows yet.');
    else if (/settings vault/.test(l)) { /* static status text, not a control */ }
    else if (/battery usage report/.test(l)) dis('Battery reporting is an Android concept; no Windows consumer exists.');
    else if (/dns group/.test(l)) dis('Per-group DNS rules are not consumed by the config builder in this build.');
    else if (/local socks port/.test(l)) dis('The SOCKS port is pinned to 10808 in this build — the TUN bridge and core verification use the same port.');
    else if (/local http port/.test(l)) dis('The config builder emits no HTTP inbound in this build.');
    else if (/domain strategy/.test(l)) {
      val.textContent = settingGet('domainStrategy') + ' ›';
      val.style.cursor = 'pointer';
      const cycleDomainStrategy = async () => {
        const cur = settingGet('domainStrategy');
        const next = DOMAIN_STRATEGIES[(DOMAIN_STRATEGIES.indexOf(cur) + 1) % DOMAIN_STRATEGIES.length];
        await persistSetting('domainStrategy', next);
        val.textContent = next + ' ›';
      };
      val.onclick = async e => { if (e && e.stopPropagation) e.stopPropagation(); await cycleDomainStrategy(); };
      // FIX-ROUND3: this row has its own inline handler (not go) —
      // give it the same whole-row binding.
      bindSrowValRow(row, val, () => { cycleDomainStrategy().catch(e => showSvcError(e)); });
    }
    else if (/custom rules/.test(l)) dis('No custom-rules editor on Windows yet.');
    else if (/direct domains|direct ips|blocked domains|proxied domains/.test(l)) dis('No rules editor on Windows yet — the routing presets above are what the builder consumes.');
    else if (/fragment packets|fragment length|fragment interval/.test(l)) dis('Fragmentation is not emitted by the Xray config builder in this build.');
    else if (/byedpi strategy/.test(l)) go(() => gotoSettingsCard('DPI Lab'));
    else if (/mux concurrency/.test(l)) dis('Mux is not emitted by the config builder in this build.');
    else if (/sudoku/.test(l)) dis('sudokubox runs Sudoku protocol profiles from Servers; it has no standalone settings surface.');
    else if (/gecko packet sizes/.test(l)) dis('Hysteria2 packet-size shaping is not consumed on Windows yet.');
    else if (/sni spoof rules/.test(l)) dis('SNI spoofing rules are not consumed by the config builder in this build.');
    else if (/excluded exit countries/.test(l)) dis('Exit-country exclusion is not consumed by any dialer on Windows yet.');
    else if (/fallback groups/.test(l)) dis('Fallback groups are not implemented on Windows yet.');
    else if (/test all parallelism/.test(l)) dis('Ping-all runs sequentially in this build.');
    else if (/delay test timeout/.test(l)) dis('The ping timeout is fixed at 3 s in this build.');
    else if (/health test interval/.test(l)) dis('Scheduled health tests are not implemented on Windows yet.');
    else if (/reconnect delay|reconnect attempts/.test(l)) dis('Auto-reconnect is not implemented on Windows yet.');
    else if (/routing by network type/.test(l)) dis('Android concept — Windows has no per-network-type routing here.');
    else if (/^regionhop$/.test(l)) go(() => gotoSettingsCard('RegionHop'));
    else if (/urnetwork source/.test(l)) go(() => { location.hash = '#/urnetwork'; });
    else if (/^username$/.test(l)) {
      val.textContent = (settingGet('lanAuthUser') || 'Not set') + ' ›';
      go(async () => {
        const u = await emberPrompt('LAN proxy username:', settingGet('lanAuthUser') || '');
        if (u == null) return;
        await persistSetting('lanAuthUser', u.trim());
        val.textContent = (u.trim() || 'Not set') + ' ›';
        showSvcNote('LAN username saved — applies on the next V2Ray connect (with LAN sharing on).');
      });
    }
    else if (/^password$/.test(l)) {
      window.ember.secrets.has('lanAuthPass').then(h => { val.textContent = h ? 'Set ›' : 'Not set ›'; }).catch(() => {});
      go(async () => {
        const p = await emberPrompt('LAN proxy password (stored only in the encrypted vault):', '', 'password');
        if (p == null) return;
        await window.ember.secrets.set('lanAuthPass', p);
        val.textContent = p ? 'Set ›' : 'Not set ›';
        showSvcNote('LAN password ' + (p ? 'saved to the vault' : 'cleared') + ' — applies on the next V2Ray connect.');
      });
    }
    else if (/browser port/.test(l)) dis('No browser-port inbound exists in this build.');
    else if (/^subscriptions$/.test(l)) go(() => { location.hash = '#/servers'; });
    else if (/subscription refresh interval/.test(l)) {
      // UI-S-B2 task 5: cycle 6/12/24/48 h (settings.subRefreshHours).
      const opts = [6, 12, 24, 48];
      val.textContent = (settingGet('subRefreshHours') || 24) + ' h ›';
      val.style.cursor = 'pointer';
      const cycleSubRefresh = async () => {
        const cur = Number(settingGet('subRefreshHours') || 24);
        const next = opts[(opts.indexOf(cur) + 1) % opts.length] || 24;
        await persistSetting('subRefreshHours', next);
        val.textContent = next + ' h ›';
        showSvcNote('Subscription refresh interval: ' + next + ' h (used by the on-launch refresh).');
      };
      val.onclick = async e => { if (e && e.stopPropagation) e.stopPropagation(); await cycleSubRefresh(); };
      // FIX-ROUND3: inline val handler — same whole-row binding.
      bindSrowValRow(row, val, () => { cycleSubRefresh().catch(e => showSvcError(e)); });
    }
    else if (/regenerate device id/.test(l)) {
      // UI-S-B2 task 5: mint a fresh random UUID into settings.hwid.
      go(async () => {
        const id = (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
          const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        }));
        await persistSetting('hwid', id);
        showSvcNote('Device ID regenerated — new subscriptions will inherit it; existing ones keep their own.');
        render();
      });
    }
    else if (/device id/.test(l)) {
      // UI-S-B2 task 5: the global HWID (default x-hwid for new
      // subscriptions; sent only via a subscription's own hwid).
      val.textContent = (settingGet('hwid') || 'Not set') + ' ›';
      go(async () => {
        const v = await emberPrompt('Device ID (HWID) — the default for new subscriptions, sent as the x-hwid header when a subscription carries it:', settingGet('hwid') || '');
        if (v == null) return;
        await persistSetting('hwid', v.trim());
        val.textContent = (v.trim() || 'Not set') + ' ›';
      });
    }
    else if (/back up v2ray data/.test(l)) go(exportBackup);
    else if (/restore v2ray data/.test(l)) go(importBackup);
    else if (/ember backup/.test(l)) go(exportBackup);
    else if (/backup & restore/.test(l)) {
      val.style.cursor = 'pointer';
      const openBackupMenu = () => showMenu(val, [
        { label: 'Export backup…', fn: () => { exportBackup().catch(e => showSvcError(e)); } },
        { label: 'Import backup…', fn: () => { importBackup().catch(e => showSvcError(e)); } },
      ]);
      val.onclick = e => { if (e && e.stopPropagation) e.stopPropagation(); openBackupMenu(); };
      // FIX-ROUND3: inline val handler — the whole row opens the
      // same menu (still anchored to .val).
      bindSrowValRow(row, val, openBackupMenu);
    }
    else if (/traffic history|traffic chart/.test(l)) dis('Per-config traffic counters are live on the Servers page (polled from the connected core); a history chart is not drawn on Windows yet.');
    else if (/smart group rules/.test(l)) dis('Smart groups are not implemented on Windows yet.');
    else if (/provider dns for servers/.test(l)) dis('Server addresses are resolved by the core; no separate provider-DNS setting is consumed.');
    else if (/run ping sweep/.test(l)) go(async () => { await pingAllProfiles(); showSvcNote('Ping sweep done — results are on the Servers page.'); });
    else if (/stall failover window/.test(l)) dis('Stall failover is an Android feature; it does not exist on Windows yet.');
    else if (/scheduled test interval/.test(l)) dis('Scheduled tests are not implemented on Windows yet.');
    else if (/quarantine/.test(l)) {
      // UI-S-B2 task 4: the auto-cut toggle (settings.sweepAutoCut).
      makeToggle(val, 'sweepAutoCut');
    }
    else if (/sweep cut threshold|sweep threshold/.test(l)) {
      // UI-S-B2 task 4: cycle 2..5 failed sweeps (settings.sweepThreshold).
      val.textContent = (settingGet('sweepThreshold') || 3) + ' failures ›';
      val.style.cursor = 'pointer';
      const cycleSweepThreshold = async () => {
        const cur = Number(settingGet('sweepThreshold') || 3);
        const next = cur >= 5 ? 2 : cur + 1;
        await persistSetting('sweepThreshold', next);
        val.textContent = next + ' failures ›';
      };
      val.onclick = async e => { if (e && e.stopPropagation) e.stopPropagation(); await cycleSweepThreshold(); };
      // FIX-ROUND3: inline val handler — same whole-row binding.
      bindSrowValRow(row, val, () => { cycleSweepThreshold().catch(e => showSvcError(e)); });
    }
    else if (/run sni scan/.test(l)) dis('The SNI scanner does not ship on Windows.');
    else if (/guided diagnosis/.test(l)) dis('The diagnosis ladder is not implemented on Windows yet.');
    else if (/ralysnd ember for windows/.test(l)) { if (meta.version) val.textContent = meta.version; }
    else if (/built by/.test(l)) dis('Nothing to open here.');
    else if (/licences/.test(l)) dis('The licence list is not bundled in this build.');
    else if (/diagnostics/.test(l)) dis('Diagnostics are not available on Windows yet.');
    else if (val.querySelector('.chev') || /›/.test(val.textContent)) dis('Nothing to open here in this build.');
  });
  /* --- dedicated cards --- */
  const logsCard = findCard('Logs');
  if (logsCard) logsCard.querySelectorAll('.val').forEach(v => {
    v.style.cursor = 'pointer';
    v.onclick = e => { if (e && e.stopPropagation) e.stopPropagation(); location.hash = '#/logs'; };
    // FIX-ROUND3: the whole Logs-card row navigates, not just .val.
    bindSrowValRow(v.closest('.srow'), v, () => { location.hash = '#/logs'; });
  });
  const rhCard = findCard('RegionHop');
  if (rhCard) wireRegionHopCard(rhCard).catch(() => {});
  const dpiCard = findCard('DPI Lab');
  if (dpiCard) wireDpiLabCard(dpiCard);
  wireAppLockRows().catch(() => {});
  // "Send problem report" (UI-S-B2 task 6) — builds the secret-free
  // report and saves it via the main-process save dialog.
  document.querySelectorAll('#app .sendbtn').forEach(b => {
    b.style.cursor = 'pointer';
    b.onclick = () => { saveProblemReport().catch(e => showSvcError(e)); };
  });
}

/* ---------- problem report (UI-S-B2 task 6) ----------
 * Secret exclusion is structural: the report carries the app
 * version, a service status snapshot, per-engine state words, the
 * selected profile's NAME + PROTOCOL ONLY (never its link,
 * address credentials, params or keys), settings keys with values
 * EXCLUDING anything secret (vault contents are never read here;
 * lanAuthUser is a username, the password is vault-only and never
 * included), and the last 200 log lines. */
const REPORT_SECRET_KEY_RE = /pass|secret|token|key|hwid/i;
function buildProblemReport() {
  const lines = [];
  lines.push('Ralysnd Ember — problem report');
  lines.push('Generated: ' + new Date().toISOString());
  lines.push('App version: ' + (meta.version || 'unknown') + ' · platform: ' + (meta.platform || 'unknown'));
  lines.push('');
  lines.push('Service: ' + (window.__lastSvcState || 'unknown'));
  lines.push('');
  lines.push('Engines:');
  for (const e of ENGINES) lines.push('  ' + e + ': ' + engineState.get(e));
  lines.push('');
  const p = selectedProfile();
  lines.push('Selected profile: ' + (p ? (p.name + ' (' + (p.protocol || '?') + ')') : 'none'));
  lines.push('');
  lines.push('Settings:');
  const s = store.settings || {};
  for (const k of Object.keys(s).sort()) {
    if (REPORT_SECRET_KEY_RE.test(k)) { lines.push('  ' + k + ': [excluded]'); continue; }
    lines.push('  ' + k + ': ' + JSON.stringify(s[k]));
  }
  lines.push('');
  lines.push('Logs (last 200 lines):');
  const tail = LOGS.lines(null).slice(-200);
  for (const e of tail) lines.push('  [' + (e.key || '') + '] ' + new Date(e.ts).toISOString() + '  ' + e.line);
  if (!tail.length) lines.push('  (no log lines received this session)');
  return lines.join('\n');
}
async function saveProblemReport() {
  if (!window.ember.saveTextFile) throw new Error('saveTextFile bridge unavailable.');
  const r = await window.ember.saveTextFile('ember-problem-report.txt', buildProblemReport());
  if (!r || r.cancelled) return;
  if (!r.ok) throw new Error(r.error || 'Saving the problem report failed.');
  showSvcNote('Problem report saved to ' + r.path + '.');
}
/* Daily report (task 6): when dailyProblemReport is on, at boot
 * write today's report via ember:saveDailyReport once per date
 * (store.lastDailyReportDate is the bookkeeping). */
async function maybeDailyReport() {
  if (settingGet('dailyProblemReport') !== true) return;
  if (!window.ember.saveDailyReport) return;
  const today = new Date().toISOString().slice(0, 10);
  if (store.lastDailyReportDate === today) return;
  const r = await window.ember.saveDailyReport(today, buildProblemReport()).catch(() => null);
  if (r && r.ok) {
    store.lastDailyReportDate = today;
    await window.ember.store.set('lastDailyReportDate', today);
  }
}

function fmtBytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
  return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}
/* ---------- speed test (UI-S-B2 task 3a) ----------
 * For the CONNECTED v2ray config: measure through its live SOCKS
 * port directly. For any other v2ray profile: a start–stop cycle —
 * build its config on the alternate SOCKS port 10811, start xray
 * under the scratch proc name 'xray-speedtest' via the service,
 * wait for the port, measure, and ALWAYS stop in a finally. The
 * download runs in main (net:speedTest) through the session proxy. */
const SPEED_TEST_URL = 'https://speed.cloudflare.com/__down?bytes=2000000';
const SPEED_TEST_PORT = 10811;
async function speedTestProfile(p) {
  if (!window.ember.speedTest) throw new Error('speedTest bridge unavailable.');
  const connectedP = trafficSession && trafficSession.profileId === p.id
    ? p : (CTRLS.v2ray.running && selectedProfileFor('v2ray') && selectedProfileFor('v2ray').id === p.id ? p : null);
  if (connectedP) {
    const port = (CTRLS.v2ray.cfg && CTRLS.v2ray.cfg.socksPort) || settingGet('socksPort');
    return window.ember.speedTest({ socksPort: port, url: SPEED_TEST_URL });
  }
  if (!['vless', 'vmess', 'trojan', 'ss', 'socks'].includes(p.protocol)) {
    throw new Error('Speed test runs on the Xray engine — "' + p.name + '" (' + p.protocol + ') cannot be speed-tested.');
  }
  const { exePath } = window.EmberControllers;
  const cfg = EP.buildXrayConfig(p, {
    socksPort: SPEED_TEST_PORT,
    remoteDns: settingGet('remoteDns'), domainStrategy: settingGet('domainStrategy'),
    routingPreset: settingGet('routingPreset'), sniffing: settingGet('sniffing'),
    fakeDns: settingGet('fakeDns'), dnsPreset: settingGet('dnsPreset'),
    dnsTransport: settingGet('dnsTransport'), localDns: settingGet('localDns'),
    listenAddress: settingGet('listenAddress'), trafficAccounting: false,
  });
  const name = 'xray-speedtest';
  try {
    await window.ember.call('proc.start', { name, exe: exePath('xray', 'xray.exe'),
      args: ['run', '-config', 'stdin:'], stdin: true });
    await window.EmberControllers.feedConfig(name, JSON.stringify(cfg, null, 1));
    await window.EmberControllers.waitSocksAnswer(SPEED_TEST_PORT, 15000);
    return await window.ember.speedTest({ socksPort: SPEED_TEST_PORT, url: SPEED_TEST_URL });
  } finally {
    try { await window.ember.call('proc.stop', { name }); } catch {}
  }
}
function speedResultText(r) {
  if (!r) return 'Speed test failed.';
  if (!r.ok) return 'Speed test failed: ' + (r.error || 'unknown error');
  return 'Speed: ' + r.mbps.toFixed(2) + ' Mbps · ' + fmtBytes(r.bytes) + ' in ' + (r.ms / 1000).toFixed(1) + ' s';
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
    const trafficTxt = ((p.upBytes || 0) + (p.downBytes || 0)) > 0
      ? ' · ↓ ' + fmtBytes(p.downBytes || 0) + ' ↑ ' + fmtBytes(p.upBytes || 0) : '';
    row.innerHTML = `<div class="flagc">${esc(protoGlyph(p))}</div>
      <div class="grow"><div class="nm">${esc(p.name)}</div>
      <div class="meta">${esc(PROTO_LABEL[p.protocol] || p.protocol)} · ${esc(p.security || '')} · ${esc(p.address)}:${p.port}${trafficTxt}</div>
      ${insecure ? '<span class="badge-ns">Not secure — unencrypted</span>' : ''}
      ${p.quarantined ? '<span class="badge-ns">QUARANTINED — ping sweep cut (restore via ⋮)</span>' : ''}</div>
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
        ...(p.quarantined ? [{ label: 'Restore from quarantine', fn: async () => {
            p.quarantined = false; p.failStreak = 0;
            await persistProfiles(); renderServersPage();
            showSvcNote('"' + p.name + '" restored from quarantine.');
          } }] : []),
        { label: 'Reset traffic', fn: async () => {
            p.upBytes = 0; p.downBytes = 0;
            await persistProfiles(); renderServersPage();
          } },
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
  const dnsChain = EP.resolveDnsServers({
    dnsPreset: settingGet('dnsPreset'), dnsTransport: settingGet('dnsTransport'),
    remoteDns: settingGet('remoteDns'), localDns: settingGet('localDns'),
  });
  const isConnectedProfile = !!(trafficSession && trafficSession.profileId === p.id);
  insp.innerHTML = `<div class="micro" style="color:var(--faint)">Selected config</div>
    <div class="nm">${esc(p.name)}</div>
    <div class="heroping"><span class="n">${p.ping != null ? p.ping : '—'}</span><span class="ms">ms</span></div>
    <div class="health"><span class="d"></span>${p.ping != null ? 'TESTED · TCP PING' : 'UNTESTED'}${p.quarantined ? ' · QUARANTINED' : ''}</div>
    <div class="facts">
      <div class="fact"><span class="k">Protocol</span><span class="v">${esc(PROTO_LABEL[p.protocol] || p.protocol)} · ${esc(p.security || '')}</span></div>
      <div class="fact"><span class="k">Address</span><span class="v">${esc(p.address)} : ${p.port}</span></div>
      <div class="fact"><span class="k">Engine</span><span class="v">${esc(ENGINE_LABEL[p.engine] || p.engine || '')}</span></div>
      <div class="fact"><span class="k">Traffic</span><span class="v">↓ ${fmtBytes(p.downBytes || 0)} · ↑ ${fmtBytes(p.upBytes || 0)}</span></div>
      <div class="fact"><span class="k">DNS chain</span><span class="v">${esc(dnsChain.join(' → ') || '—')}</span></div>
    </div>
    <div class="ds" style="margin-top:6px">DNS chain is the app-wide chain this config will use (Settings → DNS).</div>
    <div class="connectbtn">CONNECT</div>
    <div class="diag"><div class="b" id="insp-ping">Ping</div><div class="b" id="insp-speed">Speed test</div></div>
    <div class="diag"><div class="b" id="insp-dnsping">DNS ping</div><div class="b" id="insp-reset">Reset traffic</div></div>
    <div class="ds" id="insp-diag-result" style="margin-top:8px"></div>`;
  const cb = insp.querySelector('.connectbtn');
  cb.style.cursor = 'pointer';
  cb.onclick = async () => {
    if (p.engine) { await window.ember.store.set('selectedEngine', p.engine); store.selectedEngine = p.engine; }
    toggleConnect(p.engine || 'v2ray');
  };
  const pingBtn = insp.querySelector('#insp-ping');
  pingBtn.style.cursor = 'pointer';
  pingBtn.onclick = async () => { await pingProfileInto(p, pingBtn); renderServersPage(); };
  const result = insp.querySelector('#insp-diag-result');
  const speedBtn = insp.querySelector('#insp-speed');
  speedBtn.style.cursor = 'pointer';
  speedBtn.onclick = async () => {
    speedBtn.textContent = 'Testing…';
    try { result.textContent = speedResultText(await speedTestProfile(p)); }
    catch (e) { result.textContent = 'Speed test failed: ' + (e.message || e); }
    speedBtn.textContent = 'Speed test';
  };
  const dnsBtn = insp.querySelector('#insp-dnsping');
  if (!isConnectedProfile) {
    disableWithReason(dnsBtn, 'DNS ping measures through the live tunnel — connect this config first.');
  } else {
    dnsBtn.style.cursor = 'pointer';
    dnsBtn.onclick = async () => {
      if (!window.ember.dnsProbe) { result.textContent = 'DNS ping bridge unavailable.'; return; }
      const dnsServer = dnsChain.find(s => /^\d{1,3}(\.\d{1,3}){3}$/.test(s)) || '8.8.8.8';
      dnsBtn.textContent = 'Probing…';
      const r = await window.ember.dnsProbe({ socksHost: '127.0.0.1',
        socksPort: (CTRLS.v2ray.cfg && CTRLS.v2ray.cfg.socksPort) || settingGet('socksPort'),
        dnsServer }).catch(e => ({ ok: false, error: String(e.message || e) }));
      result.textContent = r.ok ? 'DNS ping (' + dnsServer + ' via this config): ' + r.ms + ' ms'
        : 'DNS ping failed: ' + (r.error || 'unknown error');
      dnsBtn.textContent = 'DNS ping';
    };
  }
  const resetBtn = insp.querySelector('#insp-reset');
  resetBtn.style.cursor = 'pointer';
  resetBtn.onclick = async () => {
    p.upBytes = 0; p.downBytes = 0;
    await persistProfiles(); renderServersPage();
  };
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
        { label: 'QR image…', fn: () => pickQrImageFile() },
        { label: 'Add subscription…', fn: async () => {
            const url = await emberPrompt('Subscription URL:');
            if (!url) return;
            try { showSvcNote(await importSubscription(url.trim())); } catch (e) { showSvcError(e); }
          } },
      ]);
    } else if (/ping all/i.test(label)) {
      b.onclick = async () => { await pingAllProfiles(); renderServersPage(); };
    } else if (/speed test/i.test(label)) {
      b.onclick = async () => {
        const p = selectedProfile();
        if (!p) { showSvcError(new Error('No config selected to speed-test.')); return; }
        const old = b.textContent; b.textContent = 'Testing…';
        try { showSvcNote(speedResultText(await speedTestProfile(p))); }
        catch (e) { showSvcError(e); }
        b.textContent = old;
      };
    } else if (/edit dns/i.test(label)) {
      b.onclick = () => gotoSettingsCard('DNS');
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

/* ---------- URnetwork SDK engine mode (UI-S-B2 task 10) ----------
 * The service's ur.* contract (ur.go) drives the REAL SDK engine:
 * Best Available connect + country picker, state from ur.status
 * ONLY. The account key comes from the vault under the SAME key
 * names the account form below has always used ('urnetwork:<id>')
 * — it is handed to ur.connect per call and never logged/stored
 * by the service. Polling is bounded: a 4 s interval that lives
 * only while the URnetwork page is shown (cleared on every
 * render) or the SDK reports connected. Managed profiles stay
 * below as the fallback. */
let urPollTimer = null;
function stopUrPolling() { if (urPollTimer) { clearInterval(urPollTimer); urPollTimer = null; } }
async function wireUrEngineSection() {
  const rows = document.querySelector('.rows');
  if (!rows || document.getElementById('ur-engine')) return;
  const UR = window.EmberControllers.ur;
  const div = document.createElement('div');
  div.className = 'krow'; div.id = 'ur-engine';
  div.innerHTML = `<div class="t"><div class="nm">SDK engine mode</div><div class="ds" id="ur-engine-state">Checking the service's URnetwork engine…</div></div>
    <div class="val"><button class="chipbtn o" id="ur-best">Best Available</button>
    <button class="chipbtn" id="ur-disconnect">Disconnect</button></div>`;
  const countryWrap = document.createElement('div');
  countryWrap.className = 'krow'; countryWrap.id = 'ur-countries-row';
  countryWrap.innerHTML = `<div class="t"><div class="nm">Country</div><div class="ds">Pick an exit country, or use Best Available.</div></div>
    <div class="val"><span class="pchips" id="ur-countries"></span></div>`;
  rows.appendChild(div); rows.appendChild(countryWrap);
  const stateEl = div.querySelector('#ur-engine-state');
  const bestBtn = div.querySelector('#ur-best');
  const discBtn = div.querySelector('#ur-disconnect');
  const chipsEl = countryWrap.querySelector('#ur-countries');
  const firstAccountKey = async () => {
    const acct = (store.urnetworkAccounts || [])[0];
    if (!acct) return null;
    return window.ember.secrets.get('urnetwork:' + acct.id).catch(() => null);
  };
  // FIX-ADV B1: the service's ur.connect is asynchronous — the
  // word painted here comes ONLY from ur.status's state machine
  // (idle/connecting/connected/failed + lastError), refreshed by
  // the poll below. Connected is painted only when status's own
  // connected field says so, never from a connect call returning.
  let lastUrErrorShown = '';
  const paint = st => {
    if (!st) { stateEl.textContent = 'URnetwork engine state unavailable.'; return; }
    if (!st.available) {
      stateEl.textContent = 'SDK engine unavailable in this service build: ' + (st.reason || 'unknown reason') +
        ' — managed profiles below remain the working path.';
      disableWithReason(bestBtn, st.reason || 'SDK engine unavailable.');
      disableWithReason(discBtn, st.reason || 'SDK engine unavailable.');
      return;
    }
    if (st.state === 'failed') {
      stateEl.textContent = 'Connect failed' + (st.lastError ? ': ' + st.lastError : '.');
      if (st.lastError && st.lastError !== lastUrErrorShown) {
        lastUrErrorShown = st.lastError;
        showSvcError(new Error(st.lastError));
      }
      return;
    }
    if (st.state === 'connecting') {
      stateEl.textContent = 'Connecting — the SDK is searching for a provider…';
      return;
    }
    stateEl.textContent = st.connected
      ? 'Connected' + (st.country ? ' — exit ' + st.country : '') +
        // FIX-ADV H2: tunneled:false on a live session means the
        // Wintun pump failed or stopped — it IS in this build.
        (st.tunneled ? ' · system traffic captured' : ' · SDK session up, but the Wintun pump is not running (failed or stopped), so system traffic is not captured')
      : 'Not connected — Best Available picks the exit, or pin a country.';
  };
  let st = null;
  try { st = await UR.status(); } catch (e) { stateEl.textContent = 'URnetwork engine check failed: ' + (e.message || e); }
  paint(st);
  if (st && st.available) {
    const key = await firstAccountKey();
    if (!key) {
      disableWithReason(bestBtn, 'Add a URnetwork account below first — its vault key is what the engine connects with.');
    } else {
      bestBtn.onclick = async () => {
        try {
          // Async connect (FIX-ADV B1): the call returns the
          // 'connecting' word at once; the poll below follows
          // ur.status to Connected or Failed from there.
          paint(await UR.connect(key, ''));
          showSvcNote('URnetwork engine: Best Available connect started — the state above follows the service\u2019s ur.status.');
        } catch (e) { showSvcError(e); }
      };
      // Country list (from the account session) as chips.
      try {
        const list = await UR.countries(key);
        if (Array.isArray(list) && list.length) {
          // The Session card's Countries stat paints from this
          // real SDK list — never a baked number (Round-1 F5).
          const sess = cardByHead(document, /session/i);
          if (sess) sess.querySelectorAll('.stat').forEach(stEl => {
            const l = stEl.querySelector('.l'); const n = stEl.querySelector('.n');
            if (l && n && /countries/i.test(l.textContent)) n.textContent = String(list.length);
          });
          chipsEl.innerHTML = list.slice(0, 24).map(cn => '<span class="pchip">' + esc(cn.name || cn.id) + '</span>').join('');
          wireChipGroup(chipsEl, async name => {
            const cn = list.find(x => (x.name || x.id) === name);
            if (!cn) return;
            try {
              paint(await UR.connect(key, cn.id || cn.name));
              showSvcNote('URnetwork engine: connecting to ' + (cn.name || cn.id) + ' — watch the state above.');
            } catch (e) { showSvcError(e); }
          });
        } else chipsEl.innerHTML = '<span class="ds">No country list from the SDK.</span>';
      } catch (e) { chipsEl.innerHTML = '<span class="ds">Country list unavailable: ' + esc(e.message || e) + '</span>'; }
    }
    discBtn.onclick = async () => {
      try { paint(await UR.disconnect()); } catch (e) { showSvcError(e); }
      render();
    };
    // Bounded polling: only while this page is shown (render
    // clears it) — refreshed state comes from ur.status only.
    stopUrPolling();
    urPollTimer = setInterval(async () => {
      if (currentScreen !== 'urnetwork') { stopUrPolling(); return; }
      try { paint(await UR.status()); } catch { /* keep last painted state */ }
    }, 4000);
  }
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
  // The engine section must be rebuilt BEFORE wireToggles so its
  // toggles get their per-engine bindings.
  if (currentScreen === 'settings') buildEngineSection();
  // Round-1 F5: paint every dynamic slot from real state BEFORE
  // the wiring passes below bind the (possibly repainted) DOM.
  paintEnginePage();
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
  if (currentScreen === 'urnetwork') { wireUrEngineSection().catch(() => {}); wireUrForm(); }
  if (currentScreen === 'logs') wireLogsPage();
}

/* ---------- traffic accounting session (UI-S-B2 task 2) ----------
 * controllers.js polls the connected core's /debug/vars and hands
 * DELTAS to EmberControllers.onTraffic. Here they accumulate into
 * the connected profile's upBytes/downBytes (persisted throttled:
 * at most every 10 s, plus a flush on disconnect) and into the
 * session total the data budget (settings.sessionBudgetMb) is
 * checked against. */
let trafficSession = null; // {engine, profileId, bytes, lastPersist}
let v2rayHopActive = false;
async function onTrafficDelta(d) {
  if (!trafficSession || !d) return;
  const p = (store.profiles || []).find(x => x.id === trafficSession.profileId);
  if (!p) return;
  p.upBytes = (p.upBytes || 0) + (d.up || 0);
  p.downBytes = (p.downBytes || 0) + (d.down || 0);
  trafficSession.bytes += (d.up || 0) + (d.down || 0);
  trafficSession.down = (trafficSession.down || 0) + (d.down || 0);
  const now = Date.now();
  if (now - trafficSession.lastPersist >= 10000) {
    trafficSession.lastPersist = now;
    await persistProfiles().catch(() => {});
    if (currentScreen === 'servers') renderServersPage();
  }
  const budgetMb = Number(settingGet('sessionBudgetMb') || 0);
  if (budgetMb > 0 && trafficSession.bytes > budgetMb * 1024 * 1024) {
    const eng = trafficSession.engine;
    showSvcNote('Session data budget passed (' + budgetMb + ' MB) — disconnecting.');
    await toggleConnect(eng).catch(() => {});
  }
}
if (window.EmberControllers) window.EmberControllers.onTraffic = d => { onTrafficDelta(d).catch(() => {}); };
async function endTrafficSession() {
  if (!trafficSession) return;
  trafficSession = null;
  await persistProfiles().catch(() => {});
}

/* ---------- connected-but-blocked watcher (FIX-ROUND2 item 2) ----------
 * The owner's standing exception (Android 2151): this alert ships
 * DEFAULT ON (settings.connectedButBlocked). While the v2ray
 * engine — or urnetwork, whose managed profiles ride the same
 * Xray core — reports Connected, evaluate every 15 s using ONLY
 * signals that already exist:
 *   (a) session downlink: the controllers' traffic poller hands
 *       deltas to onTrafficDelta above, which accumulates them
 *       into trafficSession.down (a boot-adopted session has no
 *       trafficSession, so it falls back to the connected
 *       profile's persisted downBytes growth);
 *   (b) window.ember.dnsProbe through the live SOCKS
 *       (127.0.0.1:<socksPort>) to the current remote DNS server
 *       — the same bridge and server pick as the Servers
 *       inspector's DNS ping.
 * Verdict 'blocked' only when ALL hold: toggle on, connected for
 * >= 60 s, downlink growth over the last 60 s is ~0 (<= the
 * epsilon below), and the DNS probe fails. The alert is the
 * sticky service bar; it clears when traffic resumes (or the
 * probe recovers) and on disconnect, and the user can dismiss
 * it — a dismissal holds until the verdict clears and re-fires.
 * The watcher exists ONLY while Connected: its interval is
 * created on the engineState transition into Connected and
 * cleared on the way out — no polling outside a connected
 * session. */
const BLOCKED_ALERT_TEXT = 'Connected but blocked — the tunnel is up but no traffic is passing.';
const BLOCKED_MIN_CONNECTED_MS = 60000;
const BLOCKED_WINDOW_MS = 60000;
const BLOCKED_TICK_MS = 15000;
const BLOCKED_DOWNLINK_EPSILON = 1024; // "~0 bytes" of downlink growth over the window
let blockedAlertOn = false;

/* Pure verdict (stub-tested): inputs -> alert bool. */
function blockedVerdict(v) {
  return !!(v && v.toggleOn
    && v.connectedMs >= BLOCKED_MIN_CONNECTED_MS
    && v.downlinkGrowth <= BLOCKED_DOWNLINK_EPSILON
    && !v.probeOk);
}

/* Pure alert gate (stub-tested, FIX-ADV M3): a raw verdict is
 * not always an alert. With a LIVE trafficSession the downlink
 * evidence is real, so one failed probe suffices; with the
 * persisted-counter fallback (a boot-adopted session, whose
 * downBytes can only grow via a trafficSession it does not
 * have) the evidence is weak, so TWO consecutive failed probes
 * (two watcher cycles) are required before alerting. */
function blockedAlertDue(v) {
  if (!v || !v.verdict) return false;
  if (v.liveSession) return true;
  return (v.consecutiveFails || 0) >= 2;
}

function showBlockedAlert() {
  blockedAlertOn = true;
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  const installBtn = document.getElementById('svcinstall');
  if (word) word.textContent = BLOCKED_ALERT_TEXT;
  if (installBtn) installBtn.style.display = 'none';
  if (bar) bar.classList.add('show');
}
function clearBlockedAlert() {
  if (!blockedAlertOn) return;
  blockedAlertOn = false;
  refreshServiceBar();
}

const blockedWatcher = {
  timer: null, engine: null, since: 0, samples: [], dismissed: false, failedProbes: 0,
  downlink(engine) {
    if (trafficSession && trafficSession.engine === engine) return trafficSession.down || 0;
    const p = selectedProfileFor(engine);
    return p ? (p.downBytes || 0) : 0;
  },
  sync() {
    const eng = ['v2ray', 'urnetwork'].find(e => isConnectedWord(engineState.get(e))) || null;
    if (eng && this.timer && this.engine !== eng) this.stop();
    if (eng && !this.timer) {
      this.engine = eng;
      this.since = Date.now();
      this.samples = [{ t: this.since, down: this.downlink(eng) }];
      this.dismissed = false;
      this.failedProbes = 0;
      this.timer = setInterval(() => { this.tick().catch(() => {}); }, BLOCKED_TICK_MS);
    } else if (!eng && this.timer) this.stop();
  },
  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null; this.engine = null; this.samples = []; this.failedProbes = 0;
    clearBlockedAlert();
  },
  dismiss() { this.dismissed = true; },
  async tick() {
    const eng = this.engine;
    if (!eng || !isConnectedWord(engineState.get(eng))) { this.sync(); return; }
    const now = Date.now();
    const down = this.downlink(eng);
    this.samples.push({ t: now, down });
    while (this.samples.length > 2 && this.samples[1].t <= now - BLOCKED_WINDOW_MS) this.samples.shift();
    const base = [...this.samples].reverse().find(s => s.t <= now - BLOCKED_WINDOW_MS) || this.samples[0];
    const growth = down - base.down;
    const connectedMs = now - this.since;
    const toggleOn = settingGet('connectedButBlocked') !== false;
    // Cheap gates first: the DNS probe runs only when every other
    // condition already points at 'blocked' (the probe itself
    // would otherwise add tunnel traffic to the growth signal).
    // If the bridge is unavailable the probe counts as OK — no
    // alert without a proven-failed probe.
    // FIX-ADV M3(a): the probe target is a PLAIN (non-DoH) DNS
    // server from the resolved chain. When the chain contains
    // none (a DoH-only setup), a raw-TCP probe has no valid
    // target — the probe is INAPPLICABLE and counts as OK, never
    // as a failure (the old hard-coded 8.8.8.8 fallback could
    // false-alarm a healthy DoH tunnel).
    let probeOk = true;
    if (toggleOn && connectedMs >= BLOCKED_MIN_CONNECTED_MS && growth <= BLOCKED_DOWNLINK_EPSILON
        && window.ember && typeof window.ember.dnsProbe === 'function') {
      const chain = EP.resolveDnsServers({
        dnsPreset: settingGet('dnsPreset'), dnsTransport: settingGet('dnsTransport'),
        remoteDns: settingGet('remoteDns'), localDns: settingGet('localDns'),
      });
      const dnsServer = chain.find(s => /^\d{1,3}(\.\d{1,3}){3}$/.test(s));
      if (dnsServer) {
        const c = CTRLS[eng];
        const r = await window.ember.dnsProbe({ socksHost: '127.0.0.1',
          socksPort: (c && c.cfg && c.cfg.socksPort) || settingGet('socksPort'),
          dnsServer }).catch(() => ({ ok: false }));
        probeOk = !!(r && r.ok);
      }
    }
    const verdict = blockedVerdict({ toggleOn, connectedMs, downlinkGrowth: growth, probeOk });
    // FIX-ADV M3(b): downlink evidence from the persisted-counter
    // fallback (no live trafficSession — a boot-adopted session)
    // needs TWO consecutive failed probes before the alert; a
    // live trafficSession's evidence alerts on the first.
    const liveSession = !!(trafficSession && trafficSession.engine === eng);
    this.failedProbes = verdict ? (this.failedProbes || 0) + 1 : 0;
    const due = blockedAlertDue({ verdict, liveSession, consecutiveFails: this.failedProbes });
    if (due) {
      if (!this.dismissed) showBlockedAlert();
    } else if (!verdict) {
      this.dismissed = false; // a cleared verdict re-arms the alert
      clearBlockedAlert();
    }
  },
};

/* ---------- emergency-connect walk (UI-S-B2 task 7, Android 2095) ----------
 * After a connect failure's sticky error, offer the alternatives
 * panel: every button performs a REAL action, dismiss is always
 * available. No dead buttons. */
function showEmergencyAlternatives(engine) {
  const wrap = document.createElement('div');
  wrap.className = 'ember-dialog-wrap';
  const panel = document.createElement('div');
  panel.className = 'ember-dialog';
  const msg = document.createElement('div');
  msg.className = 'ember-dialog-msg';
  msg.textContent = (ENGINE_LABEL[engine] || 'Engine') + ' did not connect. Try one of these instead:';
  panel.appendChild(msg);
  const close = () => wrap.remove();
  const addBtn = (label, fn) => {
    const b = document.createElement('button');
    b.className = 'ember-dialog-btn'; b.textContent = label;
    b.onclick = async () => { close(); try { await fn(); } catch (e) { showSvcError(e); } };
    panel.appendChild(b);
  };
  addBtn('Try next best config', async () => {
    const want = engine === 'urnetwork' ? 'v2ray' : engine;
    let candidates = (store.profiles || []).filter(p => p.engine === want && !p.quarantined && p.id !== store.selectedProfileId);
    if (!candidates.length) candidates = (store.profiles || []).filter(p => p.engine === want && !p.quarantined);
    if (!candidates.length) { showSvcNote('No other non-quarantined config to try.'); return; }
    if (candidates.every(p => p.lastPingMs == null)) await pingAllProfiles();
    candidates.sort((a, b) => (a.lastPingMs == null ? 1e9 : a.lastPingMs) - (b.lastPingMs == null ? 1e9 : b.lastPingMs));
    const best = candidates.find(p => !p.quarantined);
    if (!best) { showSvcNote('Every candidate is quarantined — restore one on the Servers page.'); return; }
    store.selectedProfileId = best.id;
    await window.ember.store.set('selectedProfileId', best.id);
    showSvcNote('Trying next best config: ' + best.name);
    await toggleConnect(engine);
  });
  addBtn('Switch capture mode and retry', async () => {
    const tun = settingGet('tunMode') !== false;
    await persistSetting('tunMode', !tun);
    await persistSetting('systemProxy', tun);
    showSvcNote('Capture mode switched to ' + (!tun ? 'TUN' : 'Proxy') + ' — retrying.');
    await toggleConnect(engine);
  });
  if (engine === 'v2ray' || engine === 'urnetwork') {
    addBtn('Enable ByeDPI hop and retry', async () => {
      await persistSetting('byedpiHop', true);
      showSvcNote('ByeDPI hop on — retrying through ciadpi.');
      await toggleConnect(engine);
    });
  }
  addBtn('Open logs', () => { location.hash = '#/logs'; });
  addBtn('Save problem report', () => saveProblemReport());
  const dismiss = document.createElement('button');
  dismiss.className = 'ember-dialog-btn ok'; dismiss.textContent = 'Dismiss';
  dismiss.onclick = close;
  panel.appendChild(dismiss);
  wrap.appendChild(panel);
  wrap.addEventListener('mousedown', ev => { if (ev.target === wrap) close(); });
  document.body.appendChild(wrap);
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
      const sb = CTRLS.singbox; // sing-box second core (hy2/tuic/naive/snell/anytls profiles)
      if (c.running || (sb && sb.running)) {
        if (sb && sb.running) await sb.stop(); else await c.stop();
        if (v2rayHopActive) { v2rayHopActive = false; await BYEDPI.stopForHop().catch(() => {}); }
        await endTrafficSession();
      }
      else {
        // The selected profile may be a sing-box profile even though
        // selectedProfileFor(engine) only matches engine 'v2ray'.
        const sel = selectedProfile();
        const p = (sel && (sel.engine === 'v2ray' || sel.engine === 'singbox')) ? sel : selectedProfileFor(engine);
        if (!p) throw new Error('No ' + ENGINE_LABEL[engine] + ' config selected — import one on the Servers page first.');
        if (p.quarantined) throw new Error('Profile "' + p.name + '" is quarantined by the ping sweep — restore it on the Servers page first.');
        if (p.engine === 'singbox') {
          // sing-box path: Xray cannot speak these protocols. The
          // config is built by profiles.js buildSingboxConfig and
          // delivered as a FILE via main (sing-box has no stdin
          // mode). No ByeDPI hop (the sing-box builder emits no
          // chaining) and no traffic counters (the poller reads the
          // Xray metrics endpoint, which sing-box does not serve —
          // the session honestly shows none).
          const sbCfg = EP.buildSingboxConfig(p, {
            remoteDns: settingGet('remoteDns'),
            dnsPreset: settingGet('dnsPreset'),
            dnsTransport: settingGet('dnsTransport'),
            localDns: settingGet('localDns'),
            listenAddress: settingGet('listenAddress'),
            lanSharing: settingGet('lanSharing'),
          });
          await sb.startWithConfig(JSON.stringify(sbCfg, null, 1));
          trafficSession = { engine, profileId: p.id, bytes: 0, down: 0, lastPersist: Date.now() };
          refreshRailStates(); refreshConnectBar();
          return;
        }
        if (!['vless', 'vmess', 'trojan', 'ss', 'socks'].includes(p.protocol)) {
          throw new Error('Profile "' + p.name + '" (' + p.protocol + ') cannot run on the Xray engine.');
        }
        // LAN auth password comes from the vault, never the store.
        const lanPass = settingGet('lanSharing')
          ? await window.ember.secrets.get('lanAuthPass').catch(() => null) : null;
        // ByeDPI hop (task 8): start ciadpi for the hop BEFORE
        // building the config that chains through it; torn down
        // on disconnect and on any connect failure below.
        let hop = null;
        if (settingGet('byedpiHop') === true) {
          await BYEDPI.startForHop();
          v2rayHopActive = true;
          hop = { host: '127.0.0.1', port: BYEDPI.socksPort };
        }
        try {
          const cfg = EP.buildXrayConfig(p, {
            socksPort: (c.cfg && c.cfg.socksPort) || settingGet('socksPort'),
            remoteDns: settingGet('remoteDns'),
            domainStrategy: settingGet('domainStrategy'),
            routingPreset: settingGet('routingPreset'),
            sniffing: settingGet('sniffing'),
            fakeDns: settingGet('fakeDns'),
            dnsPreset: settingGet('dnsPreset'),
            dnsTransport: settingGet('dnsTransport'),
            localDns: settingGet('localDns'),
            listenAddress: settingGet('listenAddress'),
            lanSharing: settingGet('lanSharing'),
            lanAuth: lanPass ? { user: settingGet('lanAuthUser'), pass: lanPass } : null,
            trafficAccounting: settingGet('trafficAccounting'),
            hop,
          });
          await c.start([], JSON.stringify(cfg, null, 1));
        } catch (e) {
          if (v2rayHopActive) { v2rayHopActive = false; await BYEDPI.stopForHop().catch(() => {}); }
          throw e;
        }
        trafficSession = { engine, profileId: p.id, bytes: 0, down: 0, lastPersist: Date.now() };
      }
    } else if (engine === 'wireguard') {
      if (c.running) await c.stop();
      else {
        const p = selectedProfileFor('wireguard');
        if (!p || !p.confText) throw new Error('No WireGuard config selected — import a .conf profile first.');
        if (p.quarantined) throw new Error('Profile "' + p.name + '" is quarantined by the ping sweep — restore it on the Servers page first.');
        // The selected profile's identity names the tunnel on the
        // service (audit W5) — never a shared constant.
        await c.start(p.confText, p.name || p.id);
      }
    } else if (engine === 'openvpn') {
      await c.toggle(selectedProfileFor('openvpn'));
    } else await c.toggle();
  } catch (e) {
    showSvcError(e); engineState.set(engine, 'Failed');
    // Emergency-connect walk (task 7): only on a CONNECT failure
    // (nothing live for this engine), never after a disconnect.
    if (!isConnectedWord(engineState.get(engine)) && !(CTRLS[engine] && CTRLS[engine].running)) {
      showEmergencyAlternatives(engine);
    }
  }
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
  window.__lastSvcState = st.state + (st.error ? ' — ' + st.error : '');
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  const installBtn = document.getElementById('svcinstall');
  const acctSvc = document.getElementById('acct-svc');
  const acctSvcVal = document.getElementById('acct-svc-val');
  // Account page service row (Round-1 F6): the SAME tri-state as the
  // svcbar, from this same snapshot — running shows 'Running.' and
  // NO install button; absent shows the button; error shows the
  // button plus the error text. No second poller: this function is
  // the single consumer of svc:status / service.state snapshots.
  const paintAcctSvc = showBtn => { if (acctSvcVal) acctSvcVal.style.display = showBtn ? '' : 'none'; };
  if (!bar || !word) { // the account page has no svcbar elements in
    // some harnesses — still paint its row from the snapshot.
    if (st.state === 'running') { if (acctSvc) acctSvc.textContent = 'Running.'; paintAcctSvc(false); }
    else if (st.state === 'error' && st.error === 'connecting') { if (acctSvc) acctSvc.textContent = 'Connecting…'; paintAcctSvc(false); }
    else if (st.state === 'error') { if (acctSvc) acctSvc.textContent = 'Error: ' + (st.error || 'unknown'); paintAcctSvc(true); }
    else { if (acctSvc) acctSvc.textContent = 'Not installed.'; paintAcctSvc(true); }
    return;
  }
  if (st.state === 'running') {
    svcStickyError = null; // state changed to running — the error's cause is gone
    if (acctSvc) acctSvc.textContent = 'Running.';
    paintAcctSvc(false);
    if (blockedAlertOn) { // the blocked alert outranks a stale note while it holds
      word.textContent = BLOCKED_ALERT_TEXT;
      if (installBtn) installBtn.style.display = 'none';
      bar.classList.add('show');
    }
    else if (svcStickyNote) { word.textContent = svcStickyNote; bar.classList.add('show'); }
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
    paintAcctSvc(false);
    return;
  }
  if (svcStickyError) { word.textContent = svcStickyError; if (acctSvc) acctSvc.textContent = svcStickyError; paintAcctSvc(true); return; }
  if (st.state === 'error') {
    word.textContent = 'Ember service error — ' + (st.error || 'the service answered but its status check failed.');
    if (acctSvc) acctSvc.textContent = 'Error: ' + (st.error || 'unknown');
    paintAcctSvc(true);
  } else { // absent — the ONLY state that may say "not installed"
    word.textContent = 'Service not installed — engine actions are unavailable until the Ember service is installed.' +
      (st.error ? ' (' + st.error + ')' : '');
    if (acctSvc) acctSvc.textContent = 'Not installed.';
    paintAcctSvc(true);
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
    reconcile({ wgProfileNames }).then(async () => {
      // settings.autoConnect consumer: connect the selected engine
      // once at boot, only when nothing was adopted live.
      if (settingGet('autoConnect') && !engineState.anyLive()) {
        await toggleConnect(store.selectedEngine || 'mozilla').catch(() => {});
      }
    }).catch(() => {});
  };
  window.__onServiceState = data => { refreshServiceBar(data); maybeReconcile(data); };
  engineState.on(() => { refreshRailStates(); refreshConnectBar(); });
  engineState.on(() => blockedWatcher.sync());
  blockedWatcher.sync();
  window.addEventListener('hashchange', render);
  document.getElementById('svcinstall').onclick = installService;
  const dismiss = document.getElementById('svcdismiss');
  if (dismiss) dismiss.onclick = () => {
    svcStickyError = null; svcStickyNote = null;
    if (blockedAlertOn) { blockedAlertOn = false; blockedWatcher.dismiss(); }
    refreshServiceBar();
  };
  // Maximize glyph follows main-process window state pushes.
  if (window.ember.onMaximizedChange) window.ember.onMaximizedChange(m => setMaxGlyph(!!m));
  // Global shortcut (UI-S-B2 task 9): main sends app:shortcutToggle
  // when Ctrl+Alt+E is registered (settings.globalShortcut) — it
  // toggle-connects the currently selected engine, same path as
  // the pill.
  if (window.ember.onShortcutToggle) {
    window.ember.onShortcutToggle(() => { toggleConnect(store.selectedEngine || 'mozilla'); });
  }
  // App lock gate: blocks before the first render when armed.
  await appLockGate();
  render();
  // Boot-only background duties (no timers): the daily problem
  // report (task 6) and the on-launch subscription refresh (task 5).
  maybeDailyReport().catch(() => {});
  refreshSubscriptionsOnBoot().catch(() => {});
  // The service may already be running before the first state
  // event arrives — check once so reconciliation is not missed.
  window.ember.serviceStatus().then(st => { if (st) maybeReconcile(st); }).catch(() => {});
}
boot().catch(e => { document.getElementById('app').textContent = 'Failed to start: ' + e.message; });
