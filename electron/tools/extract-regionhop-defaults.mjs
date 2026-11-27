// Build-time tool: converts the RegionHop defaults from their
// canonical Dart source (app/lib/regionhop/
// regionhop_defaults.dart — the real file reaches the build
// only through the CI secret, base64-encoded) into the JSON
// the Electron shell reads at runtime
// (resources/regionhop-defaults.json in the packaged app).
//
// Usage: node extract-regionhop-defaults.mjs <defaults.dart> <out.json>
//
// The tool extracts string constants by name; it contains no
// values of its own and prints none.

import { readFileSync, writeFileSync } from 'node:fs';

const FIELDS = [
  'panelUrl',
  'legacyPanelUrl',
  'panelCertificatePem',
  'panelPassword',
  'bridgeCredentials',
];

function unescapeDart(s) {
  return s.replace(/\\(.)/g, (_, c) => {
    switch (c) {
      case 'n': return '\n';
      case 'r': return '\r';
      case 't': return '\t';
      case '\\': return '\\';
      case "'": return "'";
      case '"': return '"';
      case '$': return '$';
      default: return c;
    }
  });
}

function extract(src, name) {
  const re = new RegExp(
    `static\\s+const\\s+String\\s+${name}\\s*=\\s*(?:'''([\\s\\S]*?)'''|'''([\\s\\S]*?)'''|'((?:[^'\\\\]|\\\\.)*)'|"((?:[^"\\\\]|\\\\.)*)")\\s*;`,
  );
  const m = src.match(re);
  if (!m) return null;
  if (m[1] !== undefined || m[2] !== undefined) return m[1] ?? m[2];
  return unescapeDart(m[3] ?? m[4] ?? '');
}

const [dartPath, outPath] = process.argv.slice(2);
if (!dartPath || !outPath) {
  console.error('usage: extract-regionhop-defaults.mjs <defaults.dart> <out.json>');
  process.exit(2);
}
const src = readFileSync(dartPath, 'utf8');
const out = {};
for (const f of FIELDS) {
  const v = extract(src, f);
  if (v !== null && v !== '') out[f] = v;
}
if (!out.panelUrl) {
  console.error('panelUrl not found — is this the real defaults file?');
  process.exit(1);
}
writeFileSync(outPath, JSON.stringify(out, null, 2));
console.log(`regionhop defaults extracted (${Object.keys(out).length} fields)`);
