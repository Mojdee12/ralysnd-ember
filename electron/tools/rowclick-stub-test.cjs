'use strict';
/* Row-click stub test (REPAIR 2042, FIX-ROUND3): a source-shape
 * lock for the Settings whole-row hit-area fix. Trusted-input
 * probes proved the defect: settings toggle rows answered only
 * the small .tgl knob and chevron/action rows only the small
 * .val span — clicking the row itself did nothing. The handlers
 * were correct; the hit area was wrong.
 *
 * No jsdom harness exists in this repo, so this test reads the
 * REAL renderer/app.js source and asserts the row-binding lines
 * exist for both paths (toggle + chevron go), in the style of
 * the repo's other locks. If a future edit drops a row binding,
 * this goes red.
 *
 * Run: node electron/tools/rowclick-stub-test.cjs
 * Exit code is the gate: 0 = green. */
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

let failures = 0, count = 0;
function check(name, cond, extra) {
  count++;
  if (cond) console.log('ok ' + count + ' - ' + name);
  else { failures++; console.log('NOT OK ' + count + ' - ' + name + (extra ? ' :: ' + extra : '')); }
}
/* Slice of src from the first marker to the next marker. */
function slice(from, to) {
  const a = src.indexOf(from);
  if (a < 0) return '';
  const b = to ? src.indexOf(to, a + from.length) : src.length;
  return src.slice(a, b < 0 ? src.length : b);
}

/* ---------- shared helpers ---------- */
const toggleHelper = slice('function bindSrowToggleRow', 'function wireToggles()');
check('bindSrowToggleRow exists and binds row.onclick', /row\.onclick\s*=/.test(toggleHelper));
check('toggle row handler ignores clicks originating on the knob (no double toggle)',
  /closest\('\.tgl'\)/.test(toggleHelper) && /if \(tgl\.onclick\) tgl\.onclick\(e\)/.test(toggleHelper));
check('toggle row binding only applies inside an .srow', /classList\.contains\('srow'\)/.test(toggleHelper));
check('toggle row binding mirrors the inner-controls guard (input/select/.fieldbox/.pchip rows get no row action)',
  /querySelector\('input, select, textarea, \.fieldbox, \.pchip'\)/.test(toggleHelper));
const valHelper = slice('function bindSrowValRow', 'function wireToggles()');
check('bindSrowValRow exists, binds row.onclick and ignores .val-origin clicks',
  /row\.onclick\s*=/.test(valHelper) && /closest\('\.val'\)/.test(valHelper));

/* ---------- path 1: wireToggles ---------- */
const wireToggles = slice('function wireToggles()', '/* ---------- chip buttons');
check('wireToggles standard knob click stops propagation', /tgl\.onclick = async e => \{\s*\n\s*if \(e && e\.stopPropagation\)/.test(wireToggles));
check('wireToggles binds the .srow for the standard toggle', wireToggles.includes('bindSrowToggleRow(row, tgl);'));
check('wireToggles binds the .srow for the custom lanAuth toggle',
  /wireLanAuthToggle\(tgl\); bindSrowToggleRow\(row, tgl\);/.test(wireToggles));
check('wireToggles binds the .srow for the custom sessionBudget toggle',
  /wireSessionBudgetToggle\(tgl\); bindSrowToggleRow\(row, tgl\);/.test(wireToggles));
check('disabled toggles get NO row binding (disableWithReason path returns before any bind)',
  wireToggles.indexOf('disableWithReason(tgl,') > -1 &&
  wireToggles.indexOf('disableWithReason(tgl,') < wireToggles.lastIndexOf('bindSrowToggleRow(row, tgl);'));

/* ---------- makeToggle (launcher shortcuts / quarantine / RegionHop / DPI Lab enables) ---------- */
const makeToggle = slice('function makeToggle', '/* Ping sweep');
check('makeToggle captures the .srow before replaceWith detaches the val',
  makeToggle.indexOf("valEl.closest('.srow')") > -1 &&
  makeToggle.indexOf("valEl.closest('.srow')") < makeToggle.indexOf('valEl.replaceWith(t)'));
check('makeToggle binds the whole row to the toggle (delegates to t.onclick at click time)',
  makeToggle.includes('bindSrowToggleRow(srow, t);'));
check('makeToggle knob click stops propagation', /t\.onclick = async e => \{\s*\n\s*if \(e && e\.stopPropagation\)/.test(makeToggle));

/* ---------- path 2: settings chevron loop (go / dis) ---------- */
const settings = slice('function wireSettingsPage()', '/* ---------- problem report');
const goDef = slice("const go = fn => {\n      val.style.cursor = 'pointer'; row.style.cursor = 'pointer';", 'if (/language/.test(l))');
check('settings go() binds BOTH val.onclick and row.onclick',
  /val\.onclick\s*=/.test(goDef) && /row\.onclick\s*=/.test(goDef));
check('settings go() val click stops propagation and row handler ignores .val-origin clicks (fn runs once)',
  /stopPropagation/.test(goDef) && /closest\('\.val'\)/.test(goDef));
check('settings dis() is unchanged — reason tooltip only, no row action',
  settings.includes('const dis = r => disableWithReason(val, r);'));
check('chevron loop early-return guard for inner controls is intact',
  settings.includes("if (!val || val.querySelector('.tgl') || val.querySelector('.pchip') || val.querySelector('.fieldbox') || val.querySelector('input')) return;"));
check('domain-strategy row (inline val.onclick, not go) has the row binding too',
  /bindSrowValRow\(row, val, \(\) => \{ cycleDomainStrategy\(\)/.test(settings));
check('subscription-refresh row (inline val.onclick) has the row binding too',
  /bindSrowValRow\(row, val, \(\) => \{ cycleSubRefresh\(\)/.test(settings));
check('sweep-threshold row (inline val.onclick) has the row binding too',
  /bindSrowValRow\(row, val, \(\) => \{ cycleSweepThreshold\(\)/.test(settings));
check('backup & restore row (inline val.onclick) has the row binding too',
  settings.includes('bindSrowValRow(row, val, openBackupMenu);'));
check('launcher-shortcuts row still builds its toggle via makeToggle (row binding comes from makeToggle)',
  settings.includes("makeToggle(val, 'globalShortcut')"));

/* ---------- dedicated cards ---------- */
check('Logs card rows bind the whole .srow, not just .val',
  /bindSrowValRow\(v\.closest\('\.srow'\), v, \(\) => \{ location\.hash = '#\/logs'; \}\);/.test(src));
check('DPI Lab "open the strategy lab" row binds the whole .srow',
  src.includes("bindSrowValRow(r, v, () => wrap.scrollIntoView({ block: 'center' }));"));
check('app-lock main row binds the whole .srow',
  src.includes('bindSrowValRow(row, val, () => { if (val.onclick) val.onclick(); });'));
check('app-lock PIN rows bind their whole .srows',
  src.includes("bindSrowValRow(setVal.closest('.srow'), setVal,") &&
  src.includes("bindSrowValRow(remVal.closest('.srow'), remVal,"));

/* ---------- untouched surfaces stay untouched ---------- */
const krows = slice('function wireKrows()', 'function wireEngineSection()');
check('engine-page wireKrows is unchanged in shape (already row-level)',
  krows.includes('row.onclick = () => { Promise.resolve().then(fn).catch(e => showSvcError(e)); };'));

console.log('---');
console.log(count + ' checks, ' + failures + ' failures');
process.exit(failures ? 1 : 0);
