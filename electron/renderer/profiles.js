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
 *     link?, params?, confText?, configText?, ping? }
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

function parseLink(raw) {
  const link = String(raw || '').trim();
  if (!link) throw new Error('Empty link');
  if (link.startsWith('vmess://')) return Object.assign(parseVmess(link), { id: newId(), link });
  if (link.startsWith('vless://') || link.startsWith('trojan://') || link.startsWith('ss://')) {
    let u;
    try { u = new URL(link); } catch { throw new Error('Link is not a valid URL'); }
    const p = link.startsWith('vless://') ? parseVless(u) : link.startsWith('trojan://') ? parseTrojan(u) : parseSs(link);
    return Object.assign(p, { id: newId(), link });
  }
  throw new Error('Unsupported link scheme (vless://, vmess://, trojan://, ss:// only)');
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
  return {
    id: newId(), protocol: 'wireguard', engine: 'wireguard',
    name: safeName(String(fileName || '').replace(/\.conf$/i, ''), 'WireGuard tunnel'),
    address: ep ? ep[1] : '', port: ep ? Number(ep[2]) : 51820, security: 'none',
    confText: t,
  };
}

function parseOvpn(text, fileName) {
  const t = String(text || '');
  const remote = /^\s*remote\s+(\S+)\s+(\d+)/im.exec(t);
  if (!remote && !/^\s*client\b/im.test(t)) throw new Error('Not an OpenVPN profile (no remote/client directive)');
  return {
    id: newId(), protocol: 'openvpn', engine: 'openvpn',
    name: safeName(String(fileName || '').replace(/\.ovpn$/i, ''), 'OpenVPN profile'),
    address: remote ? remote[1] : '', port: remote ? Number(remote[2]) : 1194, security: 'tls',
    configText: t,
  };
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
  throw new Error('No Xray outbound for protocol ' + p.protocol);
}

/* Complete Xray JSON for a profile: SOCKS inbound on socksPort,
 * the profile outbound tagged "proxy", direct + block. Remote DNS
 * comes from the canonical settings.remoteDns when provided;
 * routingPreset is one of global | bypass-lan | bypass-iran |
 * direct-all (canonical settings.routingPreset); domainStrategy is
 * the canonical settings.domainStrategy. */
function buildXrayConfig(profile, opts) {
  const o = opts || {};
  const socksPort = o.socksPort || 10808;
  const rules = [];
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
  const cfg = {
    log: { loglevel: 'warning' },
    inbounds: [{
      tag: 'socks-in', listen: '127.0.0.1', port: socksPort, protocol: 'socks',
      settings: { udp: true, auth: 'noauth' },
      sniffing: o.sniffing === false
        ? { enabled: false }
        : { enabled: true, destOverride: ['http', 'tls'] },
    }],
    outbounds: [
      outboundFor(profile),
      { protocol: 'freedom', tag: 'direct' },
      { protocol: 'blackhole', tag: 'block' },
    ],
    routing: { domainStrategy: o.domainStrategy || 'IPIfNonMatch', rules },
  };
  if (o.fakeDns) cfg.fakedns = [{ ipPool: '198.18.0.0/15', poolSize: 10000 }];
  if (o.remoteDns) cfg.dns = { servers: String(o.remoteDns).split(',').map(s => s.trim()).filter(Boolean) };
  return cfg;
}

window.EmberProfiles = { parseLink, parseSubscriptionBody, parseWireGuardConf, parseOvpn, buildXrayConfig, b64DecodeText };
