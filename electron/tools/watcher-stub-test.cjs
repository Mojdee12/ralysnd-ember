/* NOTE: no 'use strict' here — part 1 relies on sloppy-mode
 * direct eval leaking the extracted function declarations into
 * this module's scope, exactly like the FIX-ROUND2 original. */
/* Watcher + shell stub tests (FIX-ROUND2 originals, made
 * permanent in the repo by FIX-ADV M3 — the regression lock for
 * the connected-but-blocked watcher, the fitStage clamp, the
 * traffic poller's rebase, and the per-profile WireGuard name).
 *
 * No copies: part 1 extracts the REAL functions from
 * renderer/app.js and asserts their behaviour; part 2 loads the
 * REAL renderer/profiles.js + renderer/controllers.js under a
 * window stub (the same shape the contract suite uses) and
 * drives the REAL trafficPoller and WgEngine.
 *
 * Run: node electron/tools/watcher-stub-test.cjs
 * Exit code is the gate: 0 = all green. */
const fs = require('fs');
const path = require('path');

const rendererDir = path.join(__dirname, '..', 'renderer');
const appSrc = fs.readFileSync(path.join(rendererDir, 'app.js'), 'utf8');

let fails = 0, count = 0;
const ok = (cond, name) => {
  count++;
  console.log((cond ? 'ok   ' : 'FAIL ') + name);
  if (!cond) fails++;
};

/* ---------- part 1: extracted app.js functions ---------- */

// ---- blockedVerdict truth table ----
const consts = appSrc.match(/const BLOCKED_(MIN_CONNECTED_MS|WINDOW_MS|TICK_MS|DOWNLINK_EPSILON) = \d+;/g).join('\n');
const verdictSrc = appSrc.match(/function blockedVerdict\(v\) \{[\s\S]*?\n\}/)[0];
const dueSrc = appSrc.match(/function blockedAlertDue\(v\) \{[\s\S]*?\n\}/)[0];
eval(consts + '\n' + verdictSrc + '\n' + dueSrc);
const T = (connectedMs, downlinkGrowth, probeOk, toggleOn) =>
  blockedVerdict({ connectedMs, downlinkGrowth, probeOk, toggleOn });
ok(T(120000, 0, false, true) === true, 'verdict: all conditions met -> alert');
ok(T(120000, 0, false, false) === false, 'verdict: toggle off -> no alert');
ok(T(59999, 0, false, true) === false, 'verdict: connected 59.999s -> no alert');
ok(T(60000, 0, false, true) === true, 'verdict: connected exactly 60s -> alert');
ok(T(120000, 1024, false, true) === true, 'verdict: growth at epsilon (1024B) -> alert');
ok(T(120000, 1025, false, true) === false, 'verdict: growth above epsilon -> no alert');
ok(T(120000, 500000, false, true) === false, 'verdict: real traffic flowing -> no alert');
ok(T(120000, 0, true, true) === false, 'verdict: DNS probe OK -> no alert');
ok(T(0, 0, false, true) === false, 'verdict: just connected -> no alert');
ok(blockedVerdict(null) === false, 'verdict: null input -> no alert');

// ---- blockedAlertDue (FIX-ADV M3b): live session alerts on the
// first failed probe; the persisted-counter fallback needs two
// consecutive failed probes.
const D = (verdict, liveSession, consecutiveFails) =>
  blockedAlertDue({ verdict, liveSession, consecutiveFails });
ok(D(true, true, 1) === true, 'due: live session, first failed probe -> alert');
ok(D(true, false, 1) === false, 'due: fallback evidence, first failed probe -> hold');
ok(D(true, false, 2) === true, 'due: fallback evidence, second consecutive failed probe -> alert');
ok(D(true, false, 5) === true, 'due: fallback evidence, later consecutive failures -> alert');
ok(D(false, true, 3) === false, 'due: no verdict (live) -> no alert');
ok(D(false, false, 3) === false, 'due: no verdict (fallback) -> no alert');
ok(blockedAlertDue(null) === false, 'due: null input -> no alert');

// ---- fitStage math (incl. the FIX-ADV L5 1.5 clamp) ----
const fitSrc = appSrc.match(/function fitStage\(\) \{[\s\S]*?\n\}/)[0];
const stage = { style: {} };
global.document = { querySelector: () => stage };
global.window = { innerWidth: 0, innerHeight: 0 };
eval(fitSrc);
const run = (w, h) => {
  window.innerWidth = w; window.innerHeight = h;
  stage.style = {};
  fitStage();
  const s = parseFloat(stage.style.transform.match(/scale\(([\d.]+)\)/)[1]);
  const left = parseFloat(stage.style.left), top = parseFloat(stage.style.top);
  return { s, left, top, right: left + 1440 * s, bottom: top + 900 * s };
};
let r = run(1440, 900);
ok(r.s === 1 && r.left === 0 && r.top === 0, 'fitStage 1440x900: scale 1, zero offset (pixel-identical)');
r = run(1280, 720);
ok(Math.abs(r.s - 0.8) < 1e-9 && r.left === 64 && r.top === 0 && r.bottom === 720 && r.right === 1216,
  'fitStage 1280x720: scale .8, centred, bottom exactly at window bottom (no clip)');
r = run(1920, 1080);
ok(Math.abs(r.s - 1.2) < 1e-9 && r.left === 96 && r.top === 0 && r.bottom === 1080,
  'fitStage 1920x1080: scale 1.2, centred both axes');
r = run(1000, 1000);
ok(Math.abs(r.s - 1000 / 1440) < 1e-9 && r.left === 0 && Math.abs(r.top - (1000 - 900 * (1000 / 1440)) / 2) < 1e-9,
  'fitStage 1000x1000: width-bound, vertically centred');
r = run(3840, 2160);
ok(r.s === 1.5 && r.left === 840 && r.top === 405,
  'fitStage 3840x2160 (4K): scale clamped to 1.5, letterboxed centred (L5)');

/* ---------- part 2: the real controllers.js ---------- */
(async () => {
  const calls = [];
  let totalsText = '';
  global.window = {
    __appRoot: 'C:\\fixture',
    __emberSettings: {},
    ember: {
      call: async (method, params) => {
        calls.push({ method, params });
        if (method === 'wg.state') return { running: true, state: 'running' };
        return {};
      },
      fetchText: async () => ({ ok: true, text: totalsText }),
      tcpPing: async () => ({ ok: true }),
      onEvent: () => {},
      meta: async () => ({ version: 'stub', userData: 'C:\\fixture\\ud' }),
    },
  };
  eval(fs.readFileSync(path.join(rendererDir, 'profiles.js'), 'utf8'));
  eval(fs.readFileSync(path.join(rendererDir, 'controllers.js'), 'utf8'));
  const EC = global.window.EmberControllers;
  ok(!!EC && !!EC.trafficPoller && !!EC.controllers.wireguard, 'controllers load under the stub');

  // ---- trafficPoller (FIX-ADV M5): a totals decrease (core
  // restart) rebases — delta 0 for that sample, and the NEXT
  // sample counts only from the new baseline.
  const deltas = [];
  EC.onTraffic = d => deltas.push(d);
  const poller = EC.trafficPoller;
  const totals = (up, down) => JSON.stringify({ stats: { outbound: {
    proxy: { uplink: up, downlink: down }, metrics: { uplink: 999, downlink: 999 } } } });
  poller.last = null;
  totalsText = totals(1000, 2000);
  await poller.tick(); // baseline
  ok(deltas.length === 0, 'poller: first sample is a baseline (no delta)');
  totalsText = totals(1500, 2600);
  await poller.tick();
  ok(deltas.length === 1 && deltas[0].up === 500 && deltas[0].down === 600,
    'poller: normal growth counts the difference (metrics outbound excluded)');
  totalsText = totals(100, 200); // core restarted, counters reset
  await poller.tick();
  ok(deltas.length === 1, 'poller: totals decrease rebases — NO phantom delta counted (M5)');
  totalsText = totals(150, 260);
  await poller.tick();
  ok(deltas.length === 2 && deltas[1].up === 50 && deltas[1].down === 60,
    'poller: post-restart growth counts from the rebased baseline only');

  // ---- WgEngine per-profile name (FIX-ADV W5): the profile
  // engine carries NO fixed name, so the profile-supplied name
  // reaches wg.start sanitised to the service's charset; WARP's
  // engine keeps its fixed name.
  const wg = EC.controllers.wireguard;
  ok(wg.fixedName === null, 'W5: the wireguard engine has no fixed tunnel name');
  ok(EC.controllers.warp.wg.fixedName === 'warp', 'W5: the WARP engine keeps its fixed name');
  ok(wg.nameFor('Home NL #1') === 'Home_NL__1', 'W5: nameFor sanitises to the service charset');
  ok(wg.nameFor('') === 'ember', 'W5: an empty profile name falls back to the engine default');
  ok(wg.nameFor('...') === 'ember', 'W5: a name that sanitises to nothing falls back to the default');
  calls.length = 0;
  await wg.start('[Interface]\nPrivateKey = x\n[Peer]\n', 'Home NL #1');
  const start = calls.find(c => c.method === 'wg.start');
  ok(!!start && start.params.name === 'Home_NL__1',
    'W5: wg.start receives the sanitised PROFILE name, not a fixed constant');
  ok(wg.activeName === 'Home_NL__1', 'W5: the engine remembers the profile tunnel name for stop/state');

  console.log(fails ? ('\n' + fails + ' FAILURES') : '\nALL STUB TESTS PASS');
  process.exit(fails ? 1 : 0);
})().catch(e => { console.error('stub harness error:', e); process.exit(1); });
