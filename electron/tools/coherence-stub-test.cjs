'use strict';
/* Coherence stub test (REPAIR 2042, FIX-ROUND5): state-paint
 * coherence locks for two proven-live defects in renderer/app.js.
 *
 *  Defect 1 — hero status sentence went stale on engine pages:
 *  setHeroSub composed "Status <word> — <suffix>" only at render
 *  time (paintEnginePage), so a disconnect completing while the
 *  user stayed on the page left "Status connected — …" on screen
 *  while the pill already read CONNECT. Fix: setHeroSub caches its
 *  suffix per screen, and the engineState listener re-invokes it
 *  (cached suffix, hero line ONLY — no full paintEnginePage) when
 *  the current screen is an engine page.
 *
 *  Defect 2 — store.selectedEngine could disagree with the engine
 *  actually connected (connects also start via hash navigation,
 *  menus, the emergency walk, auto-connect and boot adoption, none
 *  of which updated the selection). Fix: the same listener adopts
 *  the connected engine on a transition INTO Connected — in memory
 *  and persisted — and never on any other transition.
 *
 * Home treatment (asserted below): home's hero is .heroword /
 * .herosub, already repainted live by refreshConnectBar in the
 * same listener, and the home template has no .hero .sub element
 * — so the listener must NOT call setHeroSub on home.
 *
 * Style follows rowclick-stub-test.cjs (source-shape locks) plus a
 * behavioural harness that evals the REAL setHeroSub and the REAL
 * listener registration extracted from app.js (and the REAL
 * isConnectedWord from controllers.js) against stubs.
 *
 * Run: node electron/tools/coherence-stub-test.cjs
 * Exit code is the gate: 0 = green. */
const fs = require('fs');
const path = require('path');

const rendererDir = path.join(__dirname, '..', 'renderer');
const src = fs.readFileSync(path.join(rendererDir, 'app.js'), 'utf8');
const ctrlSrc = fs.readFileSync(path.join(rendererDir, 'controllers.js'), 'utf8');

let failures = 0, count = 0;
function check(name, cond, extra) {
  count++;
  if (cond) console.log('ok ' + count + ' - ' + name);
  else { failures++; console.log('NOT OK ' + count + ' - ' + name + (extra ? ' :: ' + extra : '')); }
}
function sliceOf(hay, from, to) {
  const a = hay.indexOf(from);
  if (a < 0) return '';
  const b = to ? hay.indexOf(to, a + from.length) : hay.length;
  return hay.slice(a, b < 0 ? hay.length : b);
}

/* ================= source-shape locks ================= */

/* --- Defect 1: suffix cache inside setHeroSub --- */
const heroChunk = sliceOf(src, 'const heroSubSuffixByScreen', '/* The connect bar\'s cells');
check('hero suffix cache exists (module-level, keyed object)', heroChunk.length > 0);
check('setHeroSub caches a supplied suffix under the current screen',
  /heroSubSuffixByScreen\[currentScreen\] = suffix/.test(heroChunk));
check('setHeroSub reuses the cached suffix when called with no argument',
  /else suffix = heroSubSuffixByScreen\[currentScreen\]/.test(heroChunk));
check('setHeroSub still composes "Status <word> — <suffix>" from engineState',
  /sub\.innerHTML = 'Status <b>'/.test(heroChunk) && /engineState\.get\(eng\)/.test(heroChunk));

/* --- the engineState listener in boot() --- */
const listenerChunk = sliceOf(src, 'engineState.on((eng, word)', 'engineState.on(() => blockedWatcher.sync());');
check('the refresh listener now receives (eng, word)', listenerChunk.length > 0);
check('listener still refreshes rail states and the connect bar',
  listenerChunk.includes('refreshRailStates(); refreshConnectBar();'));
check('listener re-composes the hero sub on engine pages only',
  /if \(ENGINES\.includes\(currentScreen\)\) setHeroSub\(\);/.test(listenerChunk));
check('hero re-compose passes NO suffix (cached suffix is reused)',
  !/setHeroSub\([^)]/.test(listenerChunk.replace('setHeroSub();', '')));
check('listener does NOT full-repaint the engine page (page-local UI untouched)',
  !/paintEnginePage\s*\(/.test(listenerChunk));
check('blockedWatcher listener is still its own separate registration',
  src.includes('engineState.on(() => blockedWatcher.sync());'));

/* --- Defect 2: adoption on transition into Connected --- */
check('adoption is guarded by the connected word',
  /isConnectedWord\(word\)/.test(listenerChunk));
check('adoption only fires when the selection differs (loop/redundancy guard)',
  /store\.selectedEngine !== eng/.test(listenerChunk));
check('adoption updates the in-memory selection',
  /store\.selectedEngine = eng;/.test(listenerChunk));
check('adoption persists the selection',
  listenerChunk.includes("window.ember.store.set('selectedEngine', eng);"));
check('adoption runs BEFORE the rail/connect-bar refresh (home paints the adopted engine in the same pass)',
  listenerChunk.indexOf('store.selectedEngine = eng;') > -1 &&
  listenerChunk.indexOf('store.selectedEngine = eng;') < listenerChunk.indexOf('refreshRailStates();'));
check('no adoption logic on disconnect paths inside the listener (no other selectedEngine write)',
  (listenerChunk.match(/store\.selectedEngine =/g) || []).length === 1);

/* ================= behavioural harness =================
 * Eval the REAL extracted chunks in one scope with stubs. */
const isConnChunk = sliceOf(ctrlSrc, 'function isConnectedWord(word) {', '}') + '}';
check('extracted the real isConnectedWord from controllers.js', isConnChunk.includes("=== 'connected'"));
check('extracted the real listener registration', listenerChunk.trimEnd().endsWith('});'));

const R = {}; // results filled by the driver inside the eval scope
(function runHarness() {
  /* --- stubs (locals the extracted code resolves against) --- */
  let currentScreen = 'v2ray';
  const ENGINES = ['v2ray', 'mozilla', 'lantern', 'wireguard', 'warp', 'psiphon', 'openvpn', 'emberwarp', 'masque', 'urnetwork'];
  const stateMap = { v2ray: 'Idle', mozilla: 'Idle', urnetwork: 'Idle' };
  const subEl = { innerHTML: '' };
  const document = { querySelector: sel => (sel === '#app .hero .sub' ? subEl : null) };
  const esc = s => String(s == null ? '' : s);
  const store = { selectedEngine: 'urnetwork' };
  const persistCalls = [];
  const window = { ember: { store: { set: (k, v) => { persistCalls.push([k, v]); return Promise.resolve(); } } } };
  const engineOf = s => (ENGINES.includes(s) ? s : (s === 'home' || s === 'home-connected' ? store.selectedEngine : null));
  const refreshCounts = { rail: 0, bar: 0 };
  function refreshRailStates() { refreshCounts.rail++; }
  function refreshConnectBar() { refreshCounts.bar++; }
  const listeners = [];
  const engineState = { on: fn => listeners.push(fn), get: e => stateMap[e] || 'Idle' };

  const driver = `
    // 1 — setHeroSub caches the suffix it was given.
    stateMap.v2ray = 'Connected';
    setHeroSub('3 config(s) on this machine.');
    R.heroConnected = subEl.innerHTML;
    R.cachedV2ray = heroSubSuffixByScreen['v2ray'];

    // 2 — a no-arg re-compose reuses the cached suffix with the NEW word.
    stateMap.v2ray = 'Idle';
    setHeroSub();
    R.heroAfterDrop = subEl.innerHTML;

    // 3 — the cache is keyed by screen: another page keeps its own suffix.
    currentScreen = 'mozilla'; stateMap.mozilla = 'Connected';
    setHeroSub('signed in.');
    R.cachedMozilla = heroSubSuffixByScreen['mozilla'];
    currentScreen = 'v2ray'; setHeroSub();
    R.heroBackOnV2ray = subEl.innerHTML;

    // 4 — listener: Connected transition adopts + persists, refreshes, re-composes hero.
    currentScreen = 'v2ray'; stateMap.v2ray = 'Connected';
    persistCalls.length = 0; refreshCounts.rail = 0; refreshCounts.bar = 0;
    listeners[0]('v2ray', 'Connected');
    R.adopted = store.selectedEngine;
    R.persistOnConnect = persistCalls.slice();
    R.refreshed = [refreshCounts.rail, refreshCounts.bar];
    R.heroAfterListenerConnect = subEl.innerHTML;

    // 5 — listener: disconnect re-composes the hero but does NOT move the selection.
    stateMap.v2ray = 'Idle'; persistCalls.length = 0;
    listeners[0]('v2ray', 'Idle');
    R.selectionAfterDisconnect = store.selectedEngine;
    R.persistOnDisconnect = persistCalls.slice();
    R.heroAfterListenerDrop = subEl.innerHTML;

    // 6 — listener: non-Connected transitions never adopt.
    store.selectedEngine = 'mozilla'; persistCalls.length = 0;
    listeners[0]('urnetwork', 'Connecting');
    listeners[0]('urnetwork', 'Failed');
    listeners[0]('urnetwork', 'Stopping');
    R.selectionAfterNonConnected = store.selectedEngine;
    R.persistOnNonConnected = persistCalls.slice();

    // 7 — listener: Connected for the already-selected engine persists nothing.
    store.selectedEngine = 'urnetwork'; persistCalls.length = 0;
    listeners[0]('urnetwork', 'Connected');
    R.selectionWhenAlready = store.selectedEngine;
    R.persistWhenAlready = persistCalls.slice();

    // 8 — listener on Home: NO hero re-compose (home hero is refreshConnectBar's .heroword/.herosub).
    currentScreen = 'home'; subEl.innerHTML = 'SENTINEL';
    listeners[0]('mozilla', 'Idle');
    R.heroOnHome = subEl.innerHTML;

    // 9 — listener on Settings: NO hero re-compose either (engine pages only).
    currentScreen = 'settings'; subEl.innerHTML = 'SENTINEL2';
    listeners[0]('mozilla', 'Idle');
    R.heroOnSettings = subEl.innerHTML;
    R.listenerCount = listeners.length;
  `;
  eval(isConnChunk + '\n' + heroChunk + '\n' + listenerChunk + '\n' + driver);
})();

check('harness: exactly one listener was registered by the extracted code', R.listenerCount === 1);
check('harness: setHeroSub composed the connected sentence',
  R.heroConnected === 'Status <b>connected</b> — 3 config(s) on this machine.', R.heroConnected);
check('harness: setHeroSub cached the suffix for the v2ray screen', R.cachedV2ray === '3 config(s) on this machine.');
check('harness: no-arg setHeroSub re-composed with the cached suffix and the fresh (disconnected) word',
  R.heroAfterDrop === 'Status <b>disconnected</b> — 3 config(s) on this machine.', R.heroAfterDrop);
check('harness: suffix cache is keyed by screen (mozilla kept its own)',
  R.cachedMozilla === 'signed in.' && R.heroBackOnV2ray === 'Status <b>disconnected</b> — 3 config(s) on this machine.',
  R.heroBackOnV2ray);
check('harness: Connected transition adopted the connected engine into store.selectedEngine', R.adopted === 'v2ray');
check('harness: adoption persisted selectedEngine via window.ember.store.set',
  JSON.stringify(R.persistOnConnect) === JSON.stringify([['selectedEngine', 'v2ray']]), JSON.stringify(R.persistOnConnect));
check('harness: listener still refreshed rail + connect bar', JSON.stringify(R.refreshed) === JSON.stringify([1, 1]));
check('harness: listener re-composed the hero sentence to the connected word with the cached suffix',
  R.heroAfterListenerConnect === 'Status <b>connected</b> — 3 config(s) on this machine.', R.heroAfterListenerConnect);
check('harness: disconnect left the selection where it was and persisted nothing',
  R.selectionAfterDisconnect === 'v2ray' && (R.persistOnDisconnect || []).length === 0);
check('harness: disconnect re-composed the hero sentence to disconnected (the proven stale-sentence defect)',
  R.heroAfterListenerDrop === 'Status <b>disconnected</b> — 3 config(s) on this machine.', R.heroAfterListenerDrop);
check('harness: Connecting/Failed/Stopping transitions never adopt and never persist',
  R.selectionAfterNonConnected === 'mozilla' && (R.persistOnNonConnected || []).length === 0);
check('harness: Connected for the already-selected engine is a no-op (differs-guard)',
  R.selectionWhenAlready === 'urnetwork' && (R.persistWhenAlready || []).length === 0);
check('harness: on Home the listener does NOT touch the .hero .sub line (home hero is .heroword/.herosub via refreshConnectBar)',
  R.heroOnHome === 'SENTINEL', R.heroOnHome);
check('harness: on Settings the listener does NOT re-compose the hero sub', R.heroOnSettings === 'SENTINEL2');

console.log('---');
console.log(count + ' checks, ' + failures + ' failures');
process.exit(failures ? 1 : 0);
