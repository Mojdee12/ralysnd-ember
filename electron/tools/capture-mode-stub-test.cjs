'use strict';
/* Capture-mode stub test (FIX-ROUND4 regression lock): node, no
 * framework. Loads the REAL renderer/controllers.js under a window
 * stub (the watcher-stub-test.cjs shape) and drives the REAL
 * ProcEngine (controllers.v2ray) with a stubbed svc() bridge:
 *
 *  1. Proxy mode via opts.proxyMode: start issues proc.start (+ the
 *     config feed) and NO tun.start, and reaches 'Connected' on the
 *     SOCKS answer alone; stop() then issues NO tun.stop (there is
 *     no TUN session — stop mirrors start via this.tunRaised).
 *  2. Proxy mode via the single source (window.__emberSettings
 *     tunMode === false, no opts): same TUN-free start.
 *  3. TUN mode (default): start issues tun.start; when the bridge
 *     never reports 'up' (waitTunUp fails) the start rejects, the
 *     teardown issues tun.stop + proc.stop, and the state word is
 *     'Failed'.
 *  4. TUN mode success: tun.start + tun 'up' + SOCKS answer ->
 *     'Connected'; stop() issues tun.stop.
 *
 * Run: node electron/tools/capture-mode-stub-test.cjs
 * Exit code is the gate: 0 = all green. */
const fs = require('fs');
const path = require('path');

const rendererDir = path.join(__dirname, '..', 'renderer');

let fails = 0, count = 0;
const ok = (cond, name) => {
  count++;
  console.log((cond ? 'ok   ' : 'FAIL ') + name);
  if (!cond) fails++;
};

(async () => {
  const calls = [];
  let tunState = 'up';
  global.window = {
    __appRoot: 'C:\\fixture',
    __emberSettings: {},
    ember: {
      call: async (method, params) => {
        calls.push({ method, params });
        if (method === 'proc.state') return { running: true };
        if (method === 'tun.state') return { state: tunState, message: 'stub bridge ' + tunState };
        return {};
      },
      fetchText: async () => ({ ok: false, text: '' }),
      tcpPing: async () => ({ ok: true }),
      onEvent: () => {},
      meta: async () => ({ version: 'stub', userData: 'C:\\fixture\\ud' }),
      store: { get: async () => null, set: async () => {} },
    },
  };
  eval(fs.readFileSync(path.join(rendererDir, 'controllers.js'), 'utf8'));
  const EC = global.window.EmberControllers;
  ok(!!EC && !!EC.controllers.v2ray && typeof EC.captureProxyMode === 'function',
    'controllers load under the stub, captureProxyMode exported');

  const eng = EC.controllers.v2ray; // ProcEngine, xray cfg (socksPort 10808, verifySocks)
  const methods = () => calls.map(c => c.method);
  const reset = () => { calls.length = 0; eng.running = false; eng.tunRaised = false; };

  // captureProxyMode resolution: opts win, else the setting.
  ok(EC.captureProxyMode({ proxyMode: true }) === true, 'mode: opts.proxyMode true -> proxy');
  ok(EC.captureProxyMode({ proxyMode: false }) === false, 'mode: opts.proxyMode false -> TUN');
  global.window.__emberSettings = { tunMode: false };
  ok(EC.captureProxyMode() === true, 'mode: settings tunMode false -> proxy (single source)');
  ok(EC.captureProxyMode({}) === true, 'mode: empty opts fall back to the setting');
  global.window.__emberSettings = {};
  ok(EC.captureProxyMode() === false, 'mode: tunMode unset -> TUN (canonical default)');
  global.window.__emberSettings = { tunMode: true };
  ok(EC.captureProxyMode() === false, 'mode: settings tunMode true -> TUN');

  // ---- 1. Proxy mode via opts: no TUN, Connected on SOCKS alone ----
  reset(); tunState = 'down'; // even a dead bridge must not matter in proxy mode
  await eng.start([], '{"cfg":1}', { proxyMode: true });
  ok(methods().includes('proc.start'), 'proxy(opts): proc.start issued');
  ok(methods().includes('proc.write') && methods().includes('proc.close-stdin'),
    'proxy(opts): config fed via proc.write + proc.close-stdin');
  ok(!methods().includes('tun.start'), 'proxy(opts): NO tun.start issued');
  ok(!methods().includes('tun.state'), 'proxy(opts): TUN never polled (no waitTunUp)');
  ok(EC.engineState.get('v2ray') === 'Connected' && eng.running === true,
    'proxy(opts): Connected earned on the SOCKS answer alone');
  ok(eng.tunRaised === false, 'proxy(opts): tunRaised stays false');
  calls.length = 0;
  await eng.stop();
  ok(!methods().includes('tun.stop') && methods().includes('proc.stop'),
    'proxy(opts): stop issues proc.stop and NO tun.stop');

  // ---- 2. Proxy mode via the setting (no opts) ----
  reset(); global.window.__emberSettings = { tunMode: false };
  await eng.start([], '{"cfg":1}');
  ok(methods().includes('proc.start') && !methods().includes('tun.start'),
    'proxy(setting): proc.start with NO tun.start');
  ok(EC.engineState.get('v2ray') === 'Connected', 'proxy(setting): Connected');
  await eng.stop();
  global.window.__emberSettings = {};

  // ---- 3. TUN mode: waitTunUp fails -> reject + full teardown + Failed ----
  reset(); tunState = 'down';
  let threw = false;
  try { await eng.start([], '{"cfg":1}'); } catch { threw = true; }
  ok(threw, 'tun: start rejects when the bridge never reports up');
  ok(methods().includes('tun.start'), 'tun: tun.start was issued');
  const seq = methods();
  ok(seq.indexOf('tun.stop') > seq.indexOf('tun.start') && seq.includes('proc.stop'),
    'tun: teardown issues tun.stop + proc.stop after the failed start');
  ok(EC.engineState.get('v2ray') === 'Failed' && eng.running === false,
    'tun: state word Failed, engine not running');
  ok(eng.tunRaised === false, 'tun: tunRaised cleared by the teardown');

  // ---- 4. TUN mode success: stop mirrors start (tun.stop issued) ----
  reset(); tunState = 'up';
  await eng.start([], '{"cfg":1}', { proxyMode: false });
  ok(methods().includes('tun.start') && EC.engineState.get('v2ray') === 'Connected',
    'tun: tun.start issued and Connected after TUN up + SOCKS answer');
  ok(eng.tunRaised === true, 'tun: tunRaised recorded');
  calls.length = 0;
  await eng.stop();
  ok(methods().includes('tun.stop') && methods().includes('proc.stop'),
    'tun: stop issues tun.stop + proc.stop');

  console.log(fails ? ('\n' + fails + ' FAILURES') : '\nALL CAPTURE-MODE STUB TESTS PASS');
  process.exit(fails ? 1 : 0);
})().catch(e => { console.error('stub harness error:', e); process.exit(1); });
