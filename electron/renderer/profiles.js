'use strict';
/* Profile import + Xray config building — renderer side (repair 2042, B-3).
 *
 * Supported imports:
 *  - Share links: vless://, vmess:// (base64 JSON), trojan://, ss://
 *    (both the legacy base64(method:password@host:port) form and the
 *    SIP002 base64(method:password)@host:port form).
 *  - Files: .conf (WireGuard — the full config text is kept on the
 *    profile and fed to the wg.* service path at connect) and
 *    .ovpn (OpenVPN — the text is kept on the profile as configText;
 *    the service's ovpn.start takes a configPath, see app.js
 *    ensureOvpnConfigPath for how the text reaches a file).
 *  - Subscription URLs: fetched by app.js, body base64-decoded when it
 *    looks like base64, then every line parsed as a share link.
 *
 * A profile is a plain object stored via store.profiles:
 *   { id, name, protocol, address, port, security, engine, group,
 *     upBytes, downBytes, link?, params?, confText?, configText?, ping? }
 * `group` is a plain string ('' = ungrouped); `upBytes`/`downBytes`
 * are per-profile traffic counters (numbers, default 0 — the store
 * shape carries them; what increments them is the connect path's
 * business, normalizeProfile backfills them on older profiles).
 * `params` carries everything the Xray outbound builder needs
 * (uuid/password/method/flow/network/stream settings…). Profiles are
 * never partially built: parseLink either returns a complete profile
 * or throws with a human-readable reason.
 */

function b64DecodeText(s) {
  const clean = String(s || '').replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  const padded = clean + '='.repeat((4 - (clean.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = Uint8Array.from(bin, c => c.charCodeAt(0));
  return new TextDecoder('utf-8').decode(bytes);
}
function looksLikeBase64(s) {
  const t = String(s || '').trim();
  return t.length >= 16 && /^[A-Za-z0-9+/=_-]+$/.test(t) && !/:\/\//.test(t);
}
function newId() { return 'p-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8); }
function safeName(s, fallback) {
  const n = String(s || '').trim();
  return n ? n.slice(0, 80) : fallback;
}

/* ---------- share-link parsers ---------- */

function parseVless(u) {
  const uuid = decodeURIComponent(u.username || '');
  if (!uuid) throw new Error('VLESS link has no UUID');
  const q = Object.fromEntries(u.searchParams.entries());
  const name = safeName(decodeURIComponent(u.hash.replace(/^#/, '')), 'VLESS ' + u.hostname);
  return {
    protocol: 'vless', engine: 'v2ray', address: u.hostname, port: Number(u.port) || 443,
    security: q.security || 'none', name,
    params: {
      uuid, encryption: q.encryption || 'none', flow: q.flow || '',
      network: q.type || 'tcp', sni: q.sni || '', fp: q.fp || '',
      publicKey: q.pbk || '', shortId: q.sid || '', spiderX: q.spx || '',
      alpn: q.alpn || '', path: q.path || '', host: q.host || '',
      serviceName: q.serviceName || '', headerType: q.headerType || '',
      allowInsecure: q.allowInsecure === '1' || q.insecure === '1',
    },
  };
}

function parseVmess(link) {
  const payload = link.slice('vmess://'.length).split('#')[0].split('?')[0];
  let j;
  try { j = JSON.parse(b64DecodeText(payload)); } catch { throw new Error('VMess link is not valid base64 JSON'); }
  const name = safeName(j.ps, 'VMess ' + (j.add || ''));
  return {
    protocol: 'vmess', engine: 'v2ray', address: j.add || '', port: Number(j.port) || 443,
    security: j.tls || 'none', name,
    params: {
      uuid: j.id || '', alterId: Number(j.aid) || 0, cipher: j.scy || 'auto',
      network: j.net || 'tcp', sni: j.sni || '', fp: j.fp || '', alpn: j.alpn || '',
      path: j.path || '', host: j.host || '', headerType: j.type || '',
      allowInsecure: false,
    },
  };
}

function parseTrojan(u) {
  const password = decodeURIComponent(u.username || '');
  if (!password) throw new Error('Trojan link has no password');
  const q = Object.fromEntries(u.searchParams.entries());
  const name = safeName(decodeURIComponent(u.hash.replace(/^#/, '')), 'Trojan ' + u.hostname);
  return {
    protocol: 'trojan', engine: 'v2ray', address: u.hostname, port: Number(u.port) || 443,
    security: q.security || 'tls', name,
    params: {
      password, network: q.type || 'tcp', sni: q.sni || u.hostname, fp: q.fp || '',
      alpn: q.alpn || '', path: q.path || '', host: q.host || '',
      serviceName: q.serviceName || '', flow: q.flow || '',
      allowInsecure: q.allowInsecure === '1' || q.insecure === '1',
    },
  };
}

/* ---------- sing-box share-link parsers (repair 2042, SINGBOX) ----------
 * hy2:// / hysteria2://, tuic://, naive+https://, snell://, anytls:// —
 * field semantics mirror Android's src2 link_parser.dart (_hysteria2 /
 * _tuic / _naive / _snell / _anytls). These protocols cannot run on Xray;
 * profiles carry engine:'singbox' and run on the sing-box second core
 * (controllers.js SingboxEngine, buildSingboxConfig below). Like the
 * parsers above, each returns a complete profile or throws. */
function credOf(u) {
  const user = decodeURIComponent(u.username || '');
  const pass = decodeURIComponent(u.password || '');
  return pass ? user + ':' + pass : user;
}
function truthyQ(v) { return v === '1' || String(v || '').toLowerCase() === 'true' || String(v || '').toLowerCase() === 'yes'; }
function singboxBase(u, protocol, fallbackPort) {
  if (!u.hostname) throw new Error(protocol + ' link has no server host');
  const port = Number(u.port) || fallbackPort || 443;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(protocol + ' link has an invalid port');
  return { protocol, engine: 'singbox', address: u.hostname, port,
    name: safeName(decodeURIComponent(u.hash.replace(/^#/, '')), protocol + ' ' + u.hostname) };
}
function parseHysteria2(u) {
  const password = credOf(u);
  if (!password) throw new Error('Hysteria2 link has no password');
  const q = Object.fromEntries(u.searchParams.entries());
  const p = singboxBase(u, 'hysteria2', 443);
  p.security = 'tls';
  p.params = {
    password, sni: q.sni || q.peer || '', alpn: q.alpn || 'h3', fp: q.fp || '',
    obfs: q.obfs || '', obfsPassword: q['obfs-password'] || q.obfsPassword || '',
    mport: q.mport || '', upMbps: Number(q.up) || 0, downMbps: Number(q.down) || 0,
    allowInsecure: truthyQ(q.insecure) || truthyQ(q.allowInsecure),
  };
  return p;
}
function parseTuic(u) {
  const uuid = decodeURIComponent(u.username || '');
  const password = decodeURIComponent(u.password || '');
  if (!uuid) throw new Error('TUIC link has no UUID');
  const q = Object.fromEntries(u.searchParams.entries());
  const p = singboxBase(u, 'tuic', 443);
  p.security = 'tls';
  p.params = {
    uuid, password,
    congestionControl: q.congestion_control || '', udpRelayMode: q.udp_relay_mode || '',
    sni: q.sni || '', alpn: (q.alpn || '').replace(/\\,/g, ','),
    zeroRttHandshake: truthyQ(q.zero_rtt_handshake ?? q.zeroRttHandshake),
    heartbeat: q.heartbeat || '',
    udpOverStream: truthyQ(q.udp_over_stream ?? q.udpOverStream),
    disableSni: truthyQ(q.disable_sni ?? q.disableSni),
    allowInsecure: truthyQ(q.allow_insecure) || truthyQ(q.allowInsecure) || truthyQ(q.insecure),
  };
  return p;
}
function parseNaive(u) {
  const username = decodeURIComponent(u.username || '');
  const password = decodeURIComponent(u.password || '');
  if (!username && !password) throw new Error('NaiveProxy link has no credentials');
  const q = Object.fromEntries(u.searchParams.entries());
  const p = singboxBase(u, 'naive', 443);
  p.security = 'tls';
  const ic = Number(q.insecure_concurrency) || 0;
  p.params = { username, password, sni: q.sni || q.peer || '',
    insecureConcurrency: ic > 0 ? ic : 0, quic: truthyQ(q.quic) };
  return p;
}
function parseSnell(u) {
  const psk = credOf(u);
  if (!psk) throw new Error('Snell link has no PSK');
  const q = Object.fromEntries(u.searchParams.entries());
  const p = singboxBase(u, 'snell', 443);
  p.security = 'none';
  const version = Number(q.version) || 4;
  p.params = { psk, version, obfs: q.obfs || '', obfsHost: q['obfs-host'] || q.obfs_host || '' };
  return p;
}
function parseAnytls(u) {
  const password = credOf(u);
  if (!password) throw new Error('AnyTLS link has no password');
  const q = Object.fromEntries(u.searchParams.entries());
  const p = singboxBase(u, 'anytls', 443);
  p.security = 'tls';
  p.params = {
    password, sni: q.sni || q.peer || '', alpn: (q.alpn || '').replace(/\\,/g, ','), fp: q.fp || '',
    allowInsecure: truthyQ(q.insecure) || truthyQ(q.allowInsecure),
  };
  return p;
}

function parseSs(link) {
  let rest = link.slice('ss://'.length);
  const hashIdx = rest.indexOf('#');
  const name = hashIdx >= 0 ? safeName(decodeURIComponent(rest.slice(hashIdx + 1)), null) : null;
  if (hashIdx >= 0) rest = rest.slice(0, hashIdx);
  const qIdx = rest.indexOf('?');
  if (qIdx >= 0) rest = rest.slice(0, qIdx); // plugin opts are not carried into the Xray builder
  let method, password, host, port;
  const parseHostPort = s => {
    const at = s.lastIndexOf('@');
    if (at < 0) throw new Error('Shadowsocks link has no @host part');
    const hp = s.slice(at + 1);
    const colon = hp.lastIndexOf(':');
    if (colon < 0) throw new Error('Shadowsocks link has no port');
    return { userinfo: s.slice(0, at), host: hp.slice(0, colon), port: Number(hp.slice(colon + 1)) };
  };
  if (rest.includes('@') && !/^[A-Za-z0-9+/=_-]+$/.test(rest.split('@')[0])) {
    // SIP002 plain userinfo: method:password@host:port (url-encoded)
    const hp = parseHostPort(rest);
    const ui = decodeURIComponent(hp.userinfo);
    const c = ui.indexOf(':');
    method = ui.slice(0, c); password = ui.slice(c + 1);
    host = hp.host; port = hp.port;
  } else if (rest.includes('@')) {
    // SIP002: base64(method:password)@host:port
    const hp = parseHostPort(rest);
    const ui = b64DecodeText(hp.userinfo);
    const c = ui.indexOf(':');
    method = ui.slice(0, c); password = ui.slice(c + 1);
    host = hp.host; port = hp.port;
  } else {
    // Legacy: base64(method:password@host:port)
    const decoded = b64DecodeText(rest);
    const hp = parseHostPort(decoded);
    const c = hp.userinfo.indexOf(':');
    method = hp.userinfo.slice(0, c); password = hp.userinfo.slice(c + 1);
    host = hp.host; port = hp.port;
  }
  if (!method || !host || !port) throw new Error('Shadowsocks link is incomplete');
  return {
    protocol: 'ss', engine: 'v2ray', address: host, port, security: 'none',
    name: name || ('Shadowsocks ' + host),
    params: { method, password },
  };
}

/* Backfill the store-shape fields added in 2042 Phase 3 (group +
 * traffic counters) on any profile that predates them. Additive
 * only: existing values are never overwritten, and every other
 * field passes through untouched (parseLink/store compat). */
function normalizeProfile(p) {
  if (!p || typeof p !== 'object') return p;
  // UI-S-B2: lastPingMs/failStreak/quarantined are the ping-sweep
  // bookkeeping (app.js pingAllProfiles + the auto-cut quarantine).
  return Object.assign({ group: '', upBytes: 0, downBytes: 0,
    lastPingMs: null, failStreak: 0, quarantined: false }, p);
}

function parseLink(raw) {
  const link = String(raw || '').trim();
  if (!link) throw new Error('Empty link');
  if (link.startsWith('vmess://')) return normalizeProfile(Object.assign(parseVmess(link), { id: newId(), link }));
  if (link.startsWith('vless://') || link.startsWith('trojan://') || link.startsWith('ss://') ||
      link.startsWith('hy2://') || link.startsWith('hysteria2://') || link.startsWith('tuic://') ||
      link.startsWith('naive+https://') || link.startsWith('naive://') ||
      link.startsWith('snell://') || link.startsWith('anytls://')) {
    let u;
    try { u = new URL(link); } catch { throw new Error('Link is not a valid URL'); }
    const p = link.startsWith('vless://') ? parseVless(u)
      : link.startsWith('trojan://') ? parseTrojan(u)
      : link.startsWith('ss://') ? parseSs(link)
      : (link.startsWith('hy2://') || link.startsWith('hysteria2://')) ? parseHysteria2(u)
      : link.startsWith('tuic://') ? parseTuic(u)
      : (link.startsWith('naive+https://') || link.startsWith('naive://')) ? parseNaive(u)
      : link.startsWith('snell://') ? parseSnell(u)
      : parseAnytls(u);
    return normalizeProfile(Object.assign(p, { id: newId(), link }));
  }
  throw new Error('Unsupported link scheme (vless://, vmess://, trojan://, ss://, hy2://, hysteria2://, tuic://, naive+https://, snell://, anytls:// only)');
}

/* Parse a whole subscription body (already fetched). Returns
 * { profiles, errors } — bad lines are reported, never fatal. */
function parseSubscriptionBody(body) {
  let text = String(body || '');
  if (looksLikeBase64(text)) { try { text = b64DecodeText(text); } catch { /* keep raw */ } }
  const profiles = [], errors = [];
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t) continue;
    try { profiles.push(parseLink(t)); } catch (e) { errors.push(t.slice(0, 40) + '…: ' + e.message); }
  }
  return { profiles, errors };
}

/* ---------- file imports ---------- */

function parseWireGuardConf(text, fileName) {
  const t = String(text || '');
  if (!/\[Interface\]/i.test(t) || !/\[Peer\]/i.test(t)) throw new Error('Not a WireGuard config (no [Interface]/[Peer])');
  const ep = /Endpoint\s*=\s*([^\s:]+):(\d+)/i.exec(t);
  return normalizeProfile({
    id: newId(), protocol: 'wireguard', engine: 'wireguard',
    name: safeName(String(fileName || '').replace(/\.conf$/i, ''), 'WireGuard tunnel'),
    address: ep ? ep[1] : '', port: ep ? Number(ep[2]) : 51820, security: 'none',
    confText: t,
  });
}

function parseOvpn(text, fileName) {
  const t = String(text || '');
  const remote = /^\s*remote\s+(\S+)\s+(\d+)/im.exec(t);
  if (!remote && !/^\s*client\b/im.test(t)) throw new Error('Not an OpenVPN profile (no remote/client directive)');
  return normalizeProfile({
    id: newId(), protocol: 'openvpn', engine: 'openvpn',
    name: safeName(String(fileName || '').replace(/\.ovpn$/i, ''), 'OpenVPN profile'),
    address: remote ? remote[1] : '', port: remote ? Number(remote[2]) : 1194, security: 'tls',
    configText: t,
  });
}

/* ---------- profile → Xray config ---------- */

function streamSettings(p) {
  const pr = p.params || {};
  const net = pr.network || 'tcp';
  const ss = { network: net };
  const security = p.security || 'none';
  if (security === 'tls') {
    ss.security = 'tls';
    ss.tlsSettings = {
      serverName: pr.sni || p.address, fingerprint: pr.fp || 'chrome',
      allowInsecure: !!pr.allowInsecure,
    };
    if (pr.alpn) ss.tlsSettings.alpn = pr.alpn.split(',').map(s => s.trim()).filter(Boolean);
  } else if (security === 'reality') {
    ss.security = 'reality';
    ss.realitySettings = {
      serverName: pr.sni || '', fingerprint: pr.fp || 'chrome',
      publicKey: pr.publicKey || '', shortId: pr.shortId || '', spiderX: pr.spiderX || '/',
    };
  }
  if (net === 'ws') ss.wsSettings = { path: pr.path || '/', headers: pr.host ? { Host: pr.host } : {} };
  else if (net === 'grpc') ss.grpcSettings = { serviceName: pr.serviceName || '', multiMode: false };
  else if (net === 'xhttp' || net === 'splithttp') { ss.network = 'xhttp'; ss.xhttpSettings = { path: pr.path || '/', host: pr.host || '' }; }
  else if (net === 'tcp' && pr.headerType === 'http') ss.tcpSettings = { header: { type: 'http' } };
  return ss;
}

function outboundFor(p) {
  const pr = p.params || {};
  const stream = streamSettings(p);
  if (p.protocol === 'vless') {
    return { protocol: 'vless', tag: 'proxy', settings: { vnext: [{
      address: p.address, port: p.port,
      users: [{ id: pr.uuid, encryption: pr.encryption || 'none', flow: pr.flow || '' }],
    }] }, streamSettings: stream };
  }
  if (p.protocol === 'vmess') {
    return { protocol: 'vmess', tag: 'proxy', settings: { vnext: [{
      address: p.address, port: p.port,
      users: [{ id: pr.uuid, alterId: pr.alterId || 0, security: pr.cipher || 'auto' }],
    }] }, streamSettings: stream };
  }
  if (p.protocol === 'trojan') {
    return { protocol: 'trojan', tag: 'proxy', settings: { servers: [{
      address: p.address, port: p.port, password: pr.password, flow: pr.flow || '',
    }] }, streamSettings: stream };
  }
  if (p.protocol === 'ss') {
    return { protocol: 'shadowsocks', tag: 'proxy', settings: { servers: [{
      address: p.address, port: p.port, method: pr.method, password: pr.password,
    }] } };
  }
  if (p.protocol === 'socks') {
    // Plain SOCKS5 server profile — this is how RegionHop relay
    // configs (controllers.js RegionHopController.makeProfiles) run
    // on the existing V2Ray path. params.username/password carry
    // the relay auth when the relay requires it.
    const server = { address: p.address, port: p.port };
    if (pr.username) server.users = [{ user: pr.username, pass: pr.password || '' }];
    return { protocol: 'socks', tag: 'proxy', settings: { servers: [server] } };
  }
  throw new Error('No Xray outbound for protocol ' + p.protocol);
}

/* DNS presets (canonical settings.dnsPreset / dnsTransport,
 * consumed here). Only resolvers whose endpoints are established
 * public knowledge are baked in: Google (the v2rayNG default) and
 * Cloudflare. The Iranian preset chips on Android (Shecan /
 * Electro / 403 / RadarGame / Begzar) are NOT baked in — their DoH
 * endpoints are not verified anywhere in this tree; use
 * dnsPreset:'custom' + settings.remoteDns for them. */
const DNS_PRESETS = {
  google:     { doh: 'https://dns.google/dns-query',          udp: '8.8.8.8', tcp: '8.8.8.8' },
  cloudflare: { doh: 'https://cloudflare-dns.com/dns-query',  udp: '1.1.1.1', tcp: '1.1.1.1' },
};
/* Resolve the Xray dns.servers list from the canonical settings:
 *   opts.dnsPreset    'google' | 'cloudflare' | 'custom'
 *                     (absent = custom: opts.remoteDns verbatim —
 *                     the pre-Phase-3 behaviour, unchanged)
 *   opts.dnsTransport 'doh' (default) | 'udp' | 'tcp' — for 'udp' /
 *                     'tcp' the server entry is the preset's plain
 *                     resolver IP; for a custom remoteDns URL the
 *                     URL's hostname is used (a DoH URL is not a
 *                     valid plain-DNS address).
 *   opts.localDns     appended as an additional resolver entry
 *                     when provided and different from the remote
 *                     entry (v2rayNG's local-DNS fallback role).
 * Returns [] when no remote DNS is configured at all. */
function resolveDnsServers(o) {
  const transport = o.dnsTransport || 'doh';
  let remote = '';
  if (o.dnsPreset && o.dnsPreset !== 'custom' && DNS_PRESETS[o.dnsPreset]) {
    remote = DNS_PRESETS[o.dnsPreset][transport] || DNS_PRESETS[o.dnsPreset].doh;
  } else if (o.remoteDns) {
    remote = String(o.remoteDns);
    if (transport !== 'doh' && /^https?:\/\//i.test(remote)) {
      try { remote = new URL(remote).hostname; } catch { /* keep verbatim */ }
    }
  }
  const servers = String(remote || '').split(',').map(s => s.trim()).filter(Boolean);
  const local = String(o.localDns || '').trim();
  if (local && !servers.includes(local)) servers.push(local);
  return servers;
}

/* Complete Xray JSON for a profile: SOCKS inbound on socksPort,
 * the profile outbound tagged "proxy", direct + block. Remote DNS
 * comes from the canonical settings.remoteDns when provided;
 * routingPreset is one of global | bypass-lan | bypass-iran |
 * direct-all (canonical settings.routingPreset); domainStrategy is
 * the canonical settings.domainStrategy.
 *
 * Phase 3 settings consumption (all canonical settings keys; at
 * their defaults the emitted config is structurally identical to
 * the pre-Phase-3 output):
 *   dnsPreset / dnsTransport / localDns — see resolveDnsServers.
 *   listenAddress — SOCKS inbound listen (default '127.0.0.1').
 *   lanSharing    — true → inbound listen '0.0.0.0'.
 *   lanAuth       — {user, pass} (app.js reads the password from
 *                   the secret vault, key 'lanAuthPass'); only with
 *                   lanSharing, the inbound then requires SOCKS
 *                   username/password auth.
 * tunnelMtu is deliberately NOT consumed here: Xray's config has
 * no MTU knob (MTU belongs to the TUN layer, whose service
 * contract — tun.start{name,exe,socksPort,skip} — has no MTU
 * field either). See the Phase 3 remainder list. */
function buildXrayConfig(profile, opts) {
  const o = opts || {};
  const socksPort = o.socksPort || 10808;
  const lanSharing = o.lanSharing === true;
  const listen = lanSharing ? '0.0.0.0' : (o.listenAddress || '127.0.0.1');
  const socksSettings = { udp: true, auth: 'noauth' };
  if (lanSharing && o.lanAuth && o.lanAuth.user && o.lanAuth.pass) {
    socksSettings.auth = 'password';
    socksSettings.accounts = [{ user: String(o.lanAuth.user), pass: String(o.lanAuth.pass) }];
  }
  const rules = [];
  /* Traffic accounting (UI-S-B2 task 2). RULING: the canonical
   * settings.trafficAccounting defaults TRUE — it matches
   * v2rayNG/Android behaviour (the Android builder always emits
   * stats + policy system statsOutboundUplink/Downlink), so it is
   * not an Ember-added feature under the DEFAULT-OFF law. When
   * opts.trafficAccounting !== false the config gains stats:{},
   * the policy block, a metrics inbound (dokodemo-door on
   * 127.0.0.1:49201, tag 'metrics', routed to the freedom outbound
   * tagged 'metrics' that Xray's /debug/vars handler rides) and
   * its routing rule FIRST (before the preset rules, so preset
   * catch-alls never swallow it). When false, exactly the
   * pre-B2 shape is emitted. */
  const accounting = o.trafficAccounting !== false;
  if (accounting) rules.push({ type: 'field', inboundTag: ['metrics'], outboundTag: 'metrics' });
  const preset = o.routingPreset || 'global';
  if (preset === 'direct-all') {
    rules.push({ type: 'field', network: 'tcp,udp', outboundTag: 'direct' });
  } else {
    if (preset === 'bypass-lan' || preset === 'bypass-iran') {
      rules.push({ type: 'field', ip: ['geoip:private'], outboundTag: 'direct' });
    }
    if (preset === 'bypass-iran') {
      rules.push({ type: 'field', ip: ['geoip:ir'], outboundTag: 'direct' });
      rules.push({ type: 'field', domain: ['geosite:ir'], outboundTag: 'direct' });
    }
    rules.push({ type: 'field', network: 'tcp,udp', outboundTag: 'proxy' });
  }
  /* ByeDPI hop (UI-S-B2 task 8): opts.hop {host, port} points at
   * the local ciadpi SOCKS listener. The profile outbound dials
   * THROUGH a new first outbound tagged 'byedpi-hop' — the exact
   * chaining shape Android's builder emits for its zapret
   * underlay (config_builder.dart _chainThroughUnderlay): the
   * proxy outbound's streamSettings.sockopt.dialerProxy names the
   * hop tag, and the hop is a plain socks outbound. Verified
   * against the decoy core with `run -test` (see the B2 stub
   * test). ss profiles carry no streamSettings today, so one is
   * created holding only the sockopt. */
  const proxyOutbound = outboundFor(profile);
  const outbounds = [proxyOutbound,
    { protocol: 'freedom', tag: 'direct' },
    { protocol: 'blackhole', tag: 'block' }];
  if (o.hop && o.hop.host && o.hop.port) {
    proxyOutbound.streamSettings = Object.assign({}, proxyOutbound.streamSettings || {},
      { sockopt: Object.assign({}, (proxyOutbound.streamSettings || {}).sockopt || {},
        { dialerProxy: 'byedpi-hop' }) });
    outbounds.unshift({ tag: 'byedpi-hop', protocol: 'socks',
      settings: { servers: [{ address: String(o.hop.host), port: Number(o.hop.port) }] } });
  }
  if (accounting) outbounds.push({ protocol: 'freedom', tag: 'metrics' });
  const cfg = {
    log: { loglevel: 'warning' },
    inbounds: [{
      tag: 'socks-in', listen, port: socksPort, protocol: 'socks',
      settings: socksSettings,
      sniffing: o.sniffing === false
        ? { enabled: false }
        : { enabled: true, destOverride: ['http', 'tls'] },
    }],
    outbounds,
    routing: { domainStrategy: o.domainStrategy || 'IPIfNonMatch', rules },
  };
  if (accounting) {
    cfg.stats = {};
    cfg.policy = {
      levels: { '0': { statsUserUplink: false, statsUserDownlink: false, uplinkOnly: 0, downlinkOnly: 0 } },
      system: { statsInboundUplink: false, statsInboundDownlink: false,
        statsOutboundUplink: true, statsOutboundDownlink: true },
    };
    cfg.metrics = { tag: 'metrics' };
    cfg.inbounds.push({ tag: 'metrics', listen: '127.0.0.1', port: 49201,
      protocol: 'dokodemo-door', settings: { address: '127.0.0.1' } });
  }
  if (o.fakeDns) cfg.fakedns = [{ ipPool: '198.18.0.0/15', poolSize: 10000 }];
  const dnsServers = resolveDnsServers(o);
  if (dnsServers.length) cfg.dns = { servers: dnsServers };
  return cfg;
}

/* ---------- profile → sing-box config (repair 2042, SINGBOX) ----------
 * The sing-box second core serves the protocols Xray cannot speak:
 * hysteria2, tuic, naive, snell, anytls (Android: src2 singbox_config.dart,
 * whose shapes were validated against sing-box 1.14.4 — the pinned
 * Windows sidecar version, scripts/fetch-windows-sidecars.ps1).
 * Shape: log, one SOCKS inbound (127.0.0.1:20862 by default, or the
 * listenAddress/lanSharing settings exactly as buildXrayConfig
 * honours them), one outbound tagged 'proxy', route.final 'proxy'.
 * DNS mirrors the app's resolution (resolveDnsServers): a DoH URL
 * becomes a sing-box https DNS server, a plain IP a udp one.
 * Every generated shape is re-validated in this workstream against
 * the real 1.14.4 binary (`sing-box check`) — see the stub test. */
const SINGBOX_UTLS_FINGERPRINTS = new Set(['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized']);
function singboxTlsBlock(pr, address, defaultAlpn) {
  const tls = { enabled: true, server_name: pr.sni || address };
  const alpn = String(pr.alpn || '').split(',').map(s => s.trim()).filter(Boolean);
  if (alpn.length) tls.alpn = alpn;
  else if (defaultAlpn) tls.alpn = defaultAlpn;
  if (pr.allowInsecure) tls.insecure = true;
  if (pr.disableSni) tls.disable_sni = true;
  return tls;
}
function singboxServerPorts(mport) {
  const out = [];
  for (const raw of String(mport || '').split(',')) {
    const token = raw.trim(); if (!token) continue;
    const parts = token.split(/[-:]/);
    if (parts.length === 1) {
      const n = Number(parts[0]);
      if (Number.isInteger(n) && n >= 1 && n <= 65535) out.push(n + ':' + n);
    } else if (parts.length === 2) {
      const lo = Number(parts[0]), hi = Number(parts[1]);
      if (Number.isInteger(lo) && Number.isInteger(hi) && lo >= 1 && hi <= 65535 && lo <= hi) out.push(lo + ':' + hi);
    }
  }
  return out;
}
function singboxOutboundFor(p) {
  const pr = p.params || {};
  if (!p.address) throw new Error('This ' + p.protocol + ' config has no server.');
  if (!Number.isInteger(p.port) || p.port < 1 || p.port > 65535) throw new Error('This ' + p.protocol + ' config has no valid server port.');
  const base = { tag: 'proxy', server: p.address, server_port: p.port };
  if (p.protocol === 'hysteria2') {
    if (!pr.password) throw new Error('This Hysteria2 config has no password.');
    const o = Object.assign({ type: 'hysteria2' }, base, { password: pr.password });
    const hops = singboxServerPorts(pr.mport);
    if (hops.length) { o.server_ports = hops; o.hop_interval = '30s'; }
    if (pr.upMbps > 0) o.up_mbps = pr.upMbps;
    if (pr.downMbps > 0) o.down_mbps = pr.downMbps;
    if (pr.obfs) o.obfs = { type: pr.obfs, password: pr.obfsPassword || '' };
    o.tls = singboxTlsBlock(pr, p.address, ['h3']);
    return o;
  }
  if (p.protocol === 'tuic') {
    if (!pr.uuid) throw new Error('This TUIC config has no UUID.');
    const o = Object.assign({ type: 'tuic' }, base, {
      uuid: pr.uuid, congestion_control: pr.congestionControl || 'bbr',
      udp_relay_mode: pr.udpRelayMode || 'native',
    });
    if (pr.password) o.password = pr.password;
    if (pr.zeroRttHandshake) o.zero_rtt_handshake = true;
    if (pr.heartbeat) o.heartbeat = pr.heartbeat;
    if (pr.udpOverStream) o.udp_over_stream = true;
    o.tls = singboxTlsBlock(pr, p.address, ['h3']);
    return o;
  }
  if (p.protocol === 'anytls') {
    if (!pr.password) throw new Error('This AnyTLS config has no password.');
    const o = Object.assign({ type: 'anytls' }, base, { password: pr.password });
    o.tls = singboxTlsBlock(pr, p.address, null);
    const fp = String(pr.fp || '').trim().toLowerCase();
    if (SINGBOX_UTLS_FINGERPRINTS.has(fp)) o.tls.utls = { enabled: true, fingerprint: fp };
    return o;
  }
  if (p.protocol === 'snell') {
    if (!pr.psk) throw new Error('This Snell config has no key (PSK).');
    const o = Object.assign({ type: 'snell' }, base, { psk: pr.psk, version: pr.version || 4 });
    if (pr.obfs) { o.obfs_mode = pr.obfs; if (pr.obfsHost) o.obfs_host = pr.obfsHost; }
    return o;
  }
  if (p.protocol === 'naive') {
    const o = Object.assign({ type: 'naive' }, base);
    if (pr.username) o.username = pr.username;
    if (pr.password) o.password = pr.password;
    if (pr.insecureConcurrency > 0) o.insecure_concurrency = pr.insecureConcurrency;
    if (pr.quic) o.quic = true;
    if (pr.sni && pr.sni !== p.address) o.tls = singboxTlsBlock(pr, p.address, null);
    return o;
  }
  throw new Error(p.protocol + ' is not a sing-box protocol.');
}
/* buildSingboxConfig(profile, settings, opts): settings and opts are
 * both optional bags (opts wins); the recognised keys mirror
 * buildXrayConfig's: socksPort, listenAddress, lanSharing,
 * remoteDns / dnsPreset / dnsTransport / localDns. */
function buildSingboxConfig(profile, settings, opts) {
  const o = Object.assign({}, settings || {}, opts || {});
  const socksPort = o.socksPort || 20862;
  const listen = o.lanSharing === true ? '0.0.0.0' : (o.listenAddress || '127.0.0.1');
  const cfg = {
    log: { level: 'warn', timestamp: true },
    inbounds: [{ type: 'socks', tag: 'in', listen, listen_port: socksPort }],
    outbounds: [singboxOutboundFor(profile)],
    route: { final: 'proxy' },
  };
  const dnsServers = resolveDnsServers(o);
  if (dnsServers.length) {
    const servers = dnsServers.map((s, i) => {
      if (/^https?:\/\//i.test(s)) {
        try {
          const u = new URL(s);
          return { type: 'https', tag: 'dns-' + i, server: u.hostname, path: u.pathname || '/dns-query' };
        } catch { /* fall through to udp form */ }
      }
      return { type: 'udp', tag: 'dns-' + i, server: s };
    });
    /* sing-box 1.14 refuses an https DNS server whose hostname has
     * no resolver ("missing domain resolver for domain server
     * address" — proven against the real binary): point each https
     * server's domain_resolver at the first plain-udp server (the
     * app's localDns entry, appended by resolveDnsServers), or at
     * a bootstrap udp server when the list carries none. */
    let bootstrap = servers.find(s => s.type === 'udp');
    if (servers.some(s => s.type === 'https') && !bootstrap) {
      bootstrap = { type: 'udp', tag: 'dns-bootstrap', server: '8.8.8.8' };
      servers.push(bootstrap);
    }
    if (bootstrap) for (const s of servers) if (s.type === 'https') s.domain_resolver = bootstrap.tag;
    cfg.dns = { servers };
    /* With a dns block present, 1.14 also requires the outbound's
     * domain server address to name a resolver: route's
     * default_domain_resolver points at the first DNS server. */
    cfg.route.default_domain_resolver = servers[0].tag;
  }
  return cfg;
}

window.EmberProfiles = { parseLink, parseSubscriptionBody, parseWireGuardConf, parseOvpn, buildXrayConfig, buildSingboxConfig, b64DecodeText, normalizeProfile, resolveDnsServers, DNS_PRESETS };
