'use strict';
/* Ralysnd Ember — renderer SPA. Screens are the owner's approved HTML renders
 * (templates.json, extracted mechanically from windows-parity/renders);
 * this file wires them: hash routing, the rail, live engine state words,
 * real toggles (persisted; every Ember-added feature DEFAULT OFF), connect
 * bars, the service bar, URnetwork accounts and the guarded updater. */
const { controllers: CTRLS, engineState, wireServiceEvents } = window.EmberControllers;
const ENGINES = ['v2ray', 'mozilla', 'lantern', 'wireguard', 'warp', 'psiphon', 'openvpn', 'emberwarp', 'masque', 'urnetwork'];
const ENGINE_LABEL = { v2ray: 'V2Ray', mozilla: 'Mozilla', lantern: 'Lantern', wireguard: 'WireGuard', warp: 'WARP', psiphon: 'Psiphon', openvpn: 'OpenVPN', emberwarp: 'EmberWarp', masque: 'MASQUE', urnetwork: 'URnetwork' };
let templates = {}, store = {}, meta = {}, currentScreen = 'home';

const DEMO_PROFILES = [
  { id: 'demo-1', name: 'Frankfurt — VLESS', protocol: 'vless', address: 'de.example.net', port: 443, security: 'tls', engine: 'v2ray', group: 'My servers', ping: 84 },
  { id: 'demo-2', name: 'Netherlands — Trojan', protocol: 'trojan', address: 'nl.example.net', port: 443, security: 'tls', engine: 'v2ray', group: 'My servers', ping: 96 },
  { id: 'demo-3', name: 'Plain HTTP proxy', protocol: 'http', address: 'proxy.example.net', port: 8080, security: 'none', engine: 'v2ray', group: 'My servers', ping: 121 },
];

function route() {
  const h = (location.hash || '#/home').replace('#/', '');
  return ['home', 'home-connected', ...ENGINES, 'servers', 'settings', 'account'].includes(h) ? h : 'home';
}
function engineOf(screen) {
  if (ENGINES.includes(screen)) return screen;
  if (screen === 'home' || screen === 'home-connected') return (store.selectedEngine || 'mozilla');
  return null;
}

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
  wireRail(); wireControls(); refreshRailStates(); refreshServiceBar();
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
    // The renders' rail vocabulary: a connected engine reads ON.
    if (word === 'Connected') word = 'On';
    // The renders' convention: selection + the OPEN word mark
    // the engine whose own page is open (on Home/Servers/
    // Settings no engine row is selected — Home names the
    // current engine in its connect bar instead).
    const onOwnPage = ENGINES.includes(currentScreen) && engineOf(currentScreen) === eng;
    if ((word === 'Idle' || word === 'IDLE') && onOwnPage) word = 'Open';
    st.textContent = word; st.classList.toggle('live', /connected/i.test(word));
    row.classList.toggle('sel', onOwnPage);
  });
  const foot = document.querySelector('.rail .foot .micro');
  const sdot = document.querySelector('.rail .foot .sdot');
  const live = engineState.anyLive();
  if (foot) foot.textContent = live ? 'Protected' : 'Not protected';
  if (sdot) sdot.classList.toggle('green', live);
  window.ember.setProtection(live ? 'Protected' : 'Not protected');
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

function slug(s) { return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }

function wireControls() {
  // Toggles: real state, persisted under settings/engineSettings. No dead toggles.
  document.querySelectorAll('.tgl').forEach(tgl => {
    tgl.style.cursor = 'pointer';
    tgl.onclick = async () => {
      const on = !tgl.classList.contains('on'); tgl.classList.toggle('on', on);
      const row = tgl.closest('.krow,.srow');
      const label = row ? ((row.querySelector('.nm,.t') || {}).textContent || 'toggle') : 'toggle';
      const key = slug(label);
      const eng = engineOf(currentScreen);
      if (eng === 'lantern' && /smart routing/.test(key)) {
        try { await CTRLS.lantern.setSmartRouting(on); } catch (e) { showSvcError(e); tgl.classList.toggle('on', !on); return; }
      }
      if (eng) {
        store.engineSettings = store.engineSettings || {};
        store.engineSettings[eng] = store.engineSettings[eng] || {};
        store.engineSettings[eng][key] = on;
        await window.ember.store.set('engineSettings', store.engineSettings);
      } else {
        store.settings = store.settings || {}; store.settings[key] = on;
        await window.ember.store.set('settings', store.settings);
      }
    };
  });
  // Connect / disconnect pills + round power buttons.
  document.querySelectorAll('.pill').forEach(pill => {
    pill.style.cursor = 'pointer';
    pill.onclick = () => toggleConnect(engineOf(currentScreen));
  });
  document.querySelectorAll('[data-action="update"]').forEach(b => b.onclick = checkUpdate);
  document.querySelectorAll('[data-action="install-service"]').forEach(b => b.onclick = installService);
  // Servers: search filter + profile rows from the store.
  const search = document.querySelector('.search');
  if (search && currentScreen === 'servers') {
    search.innerHTML = '<input id="srv-q" placeholder="Search servers" style="flex:1;background:none;border:none">';
    document.getElementById('srv-q').oninput = e => {
      const q = e.target.value.toLowerCase();
      document.querySelectorAll('.srvrow').forEach(r => { r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none'; });
    };
  }
  document.querySelectorAll('.srvrow').forEach(r => {
    r.style.cursor = 'pointer';
    r.onclick = async () => {
      document.querySelectorAll('.srvrow').forEach(x => x.classList.remove('sel')); r.classList.add('sel');
      const nm = (r.querySelector('.nm') || {}).textContent || '';
      const p = (store.profiles || []).find(x => x.name === nm.trim());
      if (p) { await window.ember.store.set('selectedProfileId', p.id); store.selectedProfileId = p.id; }
    };
  });
  // URnetwork: account add form (key goes to the secret vault only).
  if (currentScreen === 'urnetwork') wireUrForm();
}

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

async function toggleConnect(engine) {
  if (!engine || !CTRLS[engine]) return;
  const c = CTRLS[engine];
  try {
    if (engine === 'lantern') {
      if (engineState.get('lantern') === 'Connected') await c.disconnect(); else await c.connect(store.lantern && store.lantern.selectedServer);
    } else if (engine === 'warp') {
      if (engineState.get('warp') === 'Connected') await c.disconnect(); else await c.connect();
    } else await c.toggle();
  } catch (e) { showSvcError(e); engineState.set(engine, 'Failed'); }
  refreshRailStates();
}

async function refreshServiceBar() {
  const st = await window.ember.serviceStatus().catch(() => ({ state: 'unreachable' }));
  const bar = document.getElementById('svcbar');
  const word = document.getElementById('svcword');
  const acctSvc = document.getElementById('acct-svc');
  if (st.state === 'connected') { bar.classList.remove('show'); if (acctSvc) acctSvc.textContent = 'Connected.'; }
  else {
    if (!meta.shoot) bar.classList.add('show');
    word.textContent = 'Service not installed — engine actions are unavailable until the Ember service is installed.';
    if (acctSvc) acctSvc.textContent = 'Not installed.';
  }
}
function showSvcError(e) {
  const bar = document.getElementById('svcbar');
  document.getElementById('svcword').textContent = 'Ember service: ' + (e && e.message ? e.message : String(e));
  bar.classList.add('show');
}
async function installService() {
  const r = await window.ember.installService();
  if (!r.ok) showSvcError(new Error(r.error || 'install failed'));
  else document.getElementById('svcword').textContent = 'Service installer launched — approve the elevation prompt, then reconnect.';
}
async function checkUpdate() {
  const word = document.getElementById('update-word');
  const r = await window.ember.updater.check();
  if (r.available) {
    if (word) word.textContent = `Version ${r.version} is available (${r.name}).`;
    if (confirm(`Ralysnd Ember ${r.version} is available. Open the download page?`)) window.ember.openExternal(r.url);
  } else if (word) word.textContent = r.reason || 'You are up to date.';
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
  window.__onServiceState = () => refreshServiceBar();
  engineState.on(() => refreshRailStates());
  window.addEventListener('hashchange', render);
  document.getElementById('svcinstall').onclick = installService;
  render();
}
boot().catch(e => { document.getElementById('app').textContent = 'Failed to start: ' + e.message; });
