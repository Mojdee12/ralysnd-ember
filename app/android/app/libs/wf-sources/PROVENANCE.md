# wf.jar — provenance and construction (build 2123, audit finding S-1)

## Why this jar exists

Every Psiphon start in builds ≤2121 died in
`PsiphonTunnel.buildPsiphonConfig` with `NoClassDefFoundError: Lwf/c;`
(five identical records in the owner's 2026-11-19 03:18 device export).
The Psiphon AAR (`libs/psiphon.aar`, MLM's host classes + the gomobile
runtime renamed go→pg by MLM's `repackage-psiphon-aar.py`) was compiled
against an obfuscated org.json fork (`wf.*`) and several R8 *outline
host* classes that live in MLM's app but were never bundled into Ember.
Build 2091's recovery papered over the gap with `-dontwarn wf.c` /
`-dontwarn f0.a` / `-dontwarn w3.z` in proguard-rules.pro; 2123 removes
those dontwarns and supplies the classes.

## What the AAR actually references (constant-pool sweep of the AAR)

Types: `wf/a`, `wf/b`, `wf/c` — plus outline hosts `a6/w0`,
`androidx/compose/foundation/gestures/d2`, `f0/a`, `w3/z`.
The complete method/field surface used from `wf`:
fields `wf/a.a:ArrayList`, `wf/c.a:HashMap`; methods `wf/a.k(I)String`,
`wf/c.<init>(String)`, `wf/c.D(String,Object)`, `wf/c.a(String)Object`,
`wf/c.f(String)I`, `wf/c.g(String)Lwf/a;`, `wf/c.h(String)Lwf/c;`,
`wf/c.i(String)J`, `wf/c.j(String)String`, `wf/c.n()Iterator`,
`wf/c.toString()`; `wf/b` as declared/catch exception type.

## Bundle contents

**Extracted byte-faithful from MLM 1.2.46's APK** (dex2jar 2.4.24
conversion of classes.dex / classes4.dex, zero conversion errors;
signatures cross-checked against the AAR's references above and
against dexdump class definitions):

- `wf/a` (JSONArray), `wf/b` (JSONException, extends RuntimeException),
  `wf/c` (JSONObject), `wf/d`, `wf/e` (annotations), `wf/f` (JSONTokener)
- `ug/b` — wf/c's `NULL` sentinel is an instance of it
  (`new ug.b(2)` in wf/c's `<clinit>`). **Shimmed, not extracted**
  (source in this folder): in MLM's build ug.b is an R8 synthetic
  merged class keyed by an int variant, holding several unrelated
  tiny classes (an audio resampler, a dummy MediaDrm, and org.json's
  Null sentinel as variant 2). Byte-faithful extraction was attempted
  and rejected on evidence: ug.b implements `ug.a`/`vg.a`/`z3.v`, and
  `ug.a`'s `<clinit>` instantiates `xa.e`, `ug.c`, `ug.d` — a media
  library Ember does not ship (reproduced on the JVM: loading ug.b is
  fine, but initialising it cascades into the missing classes, and
  ug.a's converted `<clinit>` is not even JVM-verifiable — it stores
  plain Objects into ug.d/ug.c-typed fields, a dex-only looseness).
  The only Lug/b; reference in the entire AAR+wf closure is wf/c's
  sentinel field, and the only operations ever performed on it are
  equals/hashCode/toString/identity — the shim reproduces variant 2's
  semantics exactly as jadx recovered them (equals: null-or-self,
  hashCode 0, toString "null", clone returns this).

**Shims** (this folder, compiled into the jar): ug.b (above) and the
five R8 outline hosts. MLM's app-build copies of `f0/a` and `w3/z`
have *different* contents (R8 outlines are per-build), so extraction
cannot satisfy the AAR's descriptors; the shims implement exactly the
referenced methods with semantics pinned from the AAR's call sites
and the identical source expressions in MLM's app build:

- `a6.w0.k/m/n/q` — jadx-verified bodies from MLM's dex.
- `f0.a.h(i, s) = s + i` — AAR call sites in pg.Seq$Ref/Seq$GoRef
  (RuntimeException "Ref instantiated with a Go refnum " + refnum;
  the app build's twin call `a.i(i, "Ref instantiated with a Go
  refnum ")` confirms prefix-then-number).
- `f0.a.l(a, b, c) = a + b + c` — call site
  `addUsableDNSServer`: l(hostAddress, "%", interfaceName).
- `w3.z.d(a, b) = new StringBuilder(a).append(b)` — call site
  PsiphonTunnel$Exception(String, Throwable): the returned builder is
  appended the cause's message and stringified as the exception text.
- `w3.z.g(a, b) = a + b` — diagnostic message concatenation in
  setCurrentActiveNetworkAndProperties (app-build twin appends
  " with DNS" to the accumulated message).
- `androidx.compose.foundation.gestures.d2.p(i, a, b) = a + i + b`,
  `d2.u(s) = new StringBuilder(s)` — jadx-verified bodies.
- `org.telegram.ui.Cells.r3.g(i, i2, s) = s.substring(i2, s.length()-i)`
  — jadx-verified body (referenced from wf/c).

## Rebuild

1. Extract with dex2jar from MLM 1.2.46 `classes4.dex` — take ONLY
   `wf/a`, `wf/b`, `wf/c`, `wf/d`, `wf/e`, `wf/f`.
2. `javac --release 8` the shim sources in this folder (a6, f0, w3,
   ug, androidx/compose/foundation/gestures,
   org/telegram/ui/Cells).
3. Zip all .class files plus this note as `libs/wf.jar`.
4. Verify: `gate/check_aar_refs.py <release.apk>` must pass, and it
   must FAIL against pkg2121 (it detects the shipped defect).
