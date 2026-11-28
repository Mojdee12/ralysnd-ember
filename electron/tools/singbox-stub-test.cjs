'use strict';
/* Sing-box stub test (repair 2042, SINGBOX workstream): node, no
 * framework. Loads the REAL renderer profiles.js with a window stub,
 * parses one fixture link per sing-box scheme, asserts the round-trip
 * fields, builds the sing-box config per protocol and asserts its
 * shape. When SINGBOX_BIN points at a real sing-box binary (the
 * pinned v1.14.4), every generated config is also written to
 * SINGBOX_CHECK_DIR (default: a temp dir) and validated with
 * `sing-box check -c` — a config the real binary rejects fails here.
 * Exit code is the gate: 0 = green. */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

global.window = {};
eval(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'profiles.js'), 'utf8'));
const EP = global.window.EmberProfiles;

let failures = 0, count = 0;
function check(name, cond, extra) {
  count++;
  if (cond) console.log('ok ' + count + ' - ' + name);
  else { failures++; console.log('NOT OK ' + count + ' - ' + name + (extra ? ' :: ' + extra : '')); }
}
function throws(name, fn, re) {
  try { fn(); check(name, false, 'did not throw'); }
  catch (e) { check(name, !re || re.test(e.message), e.message); }
}

const FIXTURES = {
  hysteria2: 'hy2://hy2pass@hy.example.net:8443?sni=cdn.example.net&obfs=salamander&obfs-password=obfspw&mport=443,8443-8444&up=20&down=100&insecure=1#Hy2%20Test',
  hysteria2Long: 'hysteria2://p%40ss@hy2.example.net:443?alpn=h3#Hy2%20Long',
  tuic: 'tuic://11111111-2222-3333-4444-555555555555:tuicpass@tuic.example.net:443?congestion_control=cubic&udp_relay_mode=quic&sni=sni.example.net&alpn=h3&zero_rtt_handshake=1&heartbeat=5s&allow_insecure=1#TUIC%20Test',
  naive: 'naive+https://naiveuser:naivepass@naive.example.net:443?sni=front.example.net&insecure_concurrency=4&quic=1#Naive%20Test',
  snell: 'snell://snellpsk@snell.example.net:8388?version=4&obfs=http&obfs-host=obfs.example.net#Snell%20Test',
  anytls: 'anytls://anytlspass@any.example.net:443?sni=tls.example.net&fp=chrome&insecure=1#AnyTLS%20Test',
};

/* ---------- parsers: round-trip fields ---------- */
const hy = EP.parseLink(FIXTURES.hysteria2);
check('hy2 parses to engine singbox / protocol hysteria2', hy.engine === 'singbox' && hy.protocol === 'hysteria2');
check('hy2 fields round-trip', hy.address === 'hy.example.net' && hy.port === 8443 &&
  hy.params.password === 'hy2pass' && hy.params.sni === 'cdn.example.net' &&
  hy.params.obfs === 'salamander' && hy.params.obfsPassword === 'obfspw' &&
  hy.params.mport === '443,8443-8444' && hy.params.upMbps === 20 && hy.params.downMbps === 100 &&
  hy.params.allowInsecure === true && hy.name === 'Hy2 Test', JSON.stringify(hy.params));
const hy2 = EP.parseLink(FIXTURES.hysteria2Long);
check('hysteria2:// long scheme parses, password url-decoded', hy2.protocol === 'hysteria2' && hy2.params.password === 'p@ss' && hy2.params.alpn === 'h3');

const tu = EP.parseLink(FIXTURES.tuic);
check('tuic parses to engine singbox', tu.engine === 'singbox' && tu.protocol === 'tuic');
check('tuic fields round-trip', tu.params.uuid === '11111111-2222-3333-4444-555555555555' &&
  tu.params.password === 'tuicpass' && tu.params.congestionControl === 'cubic' &&
  tu.params.udpRelayMode === 'quic' && tu.params.sni === 'sni.example.net' &&
  tu.params.zeroRttHandshake === true && tu.params.heartbeat === '5s' && tu.params.allowInsecure === true,
  JSON.stringify(tu.params));

const nv = EP.parseLink(FIXTURES.naive);
check('naive+https parses to engine singbox / protocol naive', nv.engine === 'singbox' && nv.protocol === 'naive');
check('naive fields round-trip', nv.params.username === 'naiveuser' && nv.params.password === 'naivepass' &&
  nv.params.sni === 'front.example.net' && nv.params.insecureConcurrency === 4 && nv.params.quic === true,
  JSON.stringify(nv.params));

const sn = EP.parseLink(FIXTURES.snell);
check('snell parses to engine singbox', sn.engine === 'singbox' && sn.protocol === 'snell');
check('snell fields round-trip', sn.params.psk === 'snellpsk' && sn.params.version === 4 &&
  sn.params.obfs === 'http' && sn.params.obfsHost === 'obfs.example.net' && sn.port === 8388,
  JSON.stringify(sn.params));

const at = EP.parseLink(FIXTURES.anytls);
check('anytls parses to engine singbox', at.engine === 'singbox' && at.protocol === 'anytls');
check('anytls fields round-trip', at.params.password === 'anytlspass' && at.params.sni === 'tls.example.net' &&
  at.params.fp === 'chrome' && at.params.allowInsecure === true, JSON.stringify(at.params));

throws('hy2 without password fails import', () => EP.parseLink('hy2://@hy.example.net:443#x'), /password/i);
throws('tuic without uuid fails import', () => EP.parseLink('tuic://@tuic.example.net:443#x'), /UUID/i);
throws('snell without psk fails import', () => EP.parseLink('snell://@snell.example.net:8388#x'), /PSK/i);
throws('anytls without password fails import', () => EP.parseLink('anytls://@any.example.net:443#x'), /password/i);
throws('naive without credentials fails import', () => EP.parseLink('naive+https://naive.example.net:443#x'), /credentials/i);
throws('unknown scheme still fails import', () => EP.parseLink('foo://x@y:1#z'), /Unsupported/);

/* ---------- buildSingboxConfig: shape per protocol ---------- */
const SETTINGS = { remoteDns: 'https://dns.google/dns-query', dnsPreset: 'google', dnsTransport: 'doh', localDns: '8.8.8.8' };
const built = {};
for (const [key, profile] of Object.entries({ hysteria2: hy, tuic: tu, naive: nv, snell: sn, anytls: at })) {
  const cfg = EP.buildSingboxConfig(profile, SETTINGS);
  built[key] = cfg;
  const inbound = cfg.inbounds && cfg.inbounds[0];
  const out = cfg.outbounds && cfg.outbounds[0];
  check(key + ' config: socks inbound 127.0.0.1:20862 + route final proxy',
    !!inbound && inbound.type === 'socks' && inbound.listen === '127.0.0.1' && inbound.listen_port === 20862 &&
    cfg.route && cfg.route.final === 'proxy', JSON.stringify(cfg));
  check(key + ' config: outbound type/server/port', !!out && out.type === key &&
    out.server === profile.address && out.server_port === profile.port, JSON.stringify(out));
  check(key + ' config: dns carries the app resolver as an https server',
    Array.isArray(cfg.dns && cfg.dns.servers) && cfg.dns.servers.some(s => s.type === 'https' && s.server === 'dns.google'),
    JSON.stringify(cfg.dns));
}
check('hysteria2 outbound: obfs + server_ports + tls h3', (() => {
  const o = built.hysteria2.outbounds[0];
  return o.obfs && o.obfs.type === 'salamander' && o.obfs.password === 'obfspw' &&
    JSON.stringify(o.server_ports) === '["443:443","8443:8444"]' && o.hop_interval === '30s' &&
    o.up_mbps === 20 && o.down_mbps === 100 && o.tls.enabled === true &&
    o.tls.server_name === 'cdn.example.net' && o.tls.insecure === true &&
    JSON.stringify(o.tls.alpn) === '["h3"]';
})(), JSON.stringify(built.hysteria2.outbounds[0]));
check('tuic outbound: uuid/password/cc/udp-relay + tls', (() => {
  const o = built.tuic.outbounds[0];
  return o.uuid === tu.params.uuid && o.password === 'tuicpass' && o.congestion_control === 'cubic' &&
    o.udp_relay_mode === 'quic' && o.zero_rtt_handshake === true && o.heartbeat === '5s' &&
    o.tls.server_name === 'sni.example.net' && o.tls.insecure === true;
})(), JSON.stringify(built.tuic.outbounds[0]));
check('naive outbound: user/pass + insecure_concurrency + quic + tls', (() => {
  const o = built.naive.outbounds[0];
  return o.username === 'naiveuser' && o.password === 'naivepass' && o.insecure_concurrency === 4 &&
    o.quic === true && o.tls && o.tls.server_name === 'front.example.net';
})(), JSON.stringify(built.naive.outbounds[0]));
check('snell outbound: psk/version/obfs', (() => {
  const o = built.snell.outbounds[0];
  return o.psk === 'snellpsk' && o.version === 4 && o.obfs_mode === 'http' && o.obfs_host === 'obfs.example.net' && !o.tls;
})(), JSON.stringify(built.snell.outbounds[0]));
check('anytls outbound: password + tls + utls chrome', (() => {
  const o = built.anytls.outbounds[0];
  return o.password === 'anytlspass' && o.tls.server_name === 'tls.example.net' &&
    o.tls.utls && o.tls.utls.fingerprint === 'chrome' && o.tls.insecure === true;
})(), JSON.stringify(built.anytls.outbounds[0]));

/* ---------- real binary: sing-box check per protocol ---------- */
const bin = process.env.SINGBOX_BIN || '';
if (bin) {
  const dir = process.env.SINGBOX_CHECK_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'ember-singbox-check-'));
  fs.mkdirSync(dir, { recursive: true });
  for (const [key, cfg] of Object.entries(built)) {
    const file = path.join(dir, key + '.json');
    fs.writeFileSync(file, JSON.stringify(cfg, null, 1));
    let ok = true, out = '';
    try { execFileSync(bin, ['check', '-c', file], { encoding: 'utf8' }); }
    catch (e) { ok = false; out = String((e.stdout || '') + (e.stderr || '')); }
    check('sing-box check accepts the ' + key + ' config (' + file + ')', ok, out.trim());
  }
} else {
  console.log('note: SINGBOX_BIN unset — real-binary check skipped (shape assertions only)');
}

console.log('---');
console.log(count + ' checks, ' + failures + ' failures');
process.exit(failures ? 1 : 0);
