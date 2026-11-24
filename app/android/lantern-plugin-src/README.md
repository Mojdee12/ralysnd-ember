# Lantern plugin dexes — provenance and rebuild (build 2129)

The Lantern engine's Java side ships as two dex assets, loaded by
`LanternVpnService` (:lantern process) through a child-first
`DexClassLoader` — the plugin-dex pattern. A compile-time AAR is
not possible: the bindings' `go.*` classes would collide with the
Mozilla `core.aar`'s `go.*` in the main dex.

## assets/lantern-plugin.dex — the official bindings (trust chain)

Contents: `go.*` + `lantern.io.*` (116 classes) — the official
Lantern Android **v10.0.5-beta.1** app's own gomobile bindings,
taken from the official APK (`org.getlantern.lantern`,
versionName exactly 10.0.5-beta.1; APK sha256
0edc4de208a65da024a603768a56d6cf55c838fd2b8e060f1e084fd024336ec3,
== GitHub's published asset digest == the hash in LML's
THIRD-PARTY-NOTICES; see `~/workspace/ember-app/build2129-phase0.md`).

Build steps (2026-11-21, tooling: baksmali/smali 2.5.2):

1. Extract `classes3.dex` (holds `go/*`) and `classes4.dex`
   (holds `lantern/*`) from the official APK.
2. `baksmali disassemble` both; keep only `go/` and `lantern/`.
3. ONE disclosed patch, in `go/Seq.smali`:
   `const-string v0, "gojni"` → `const-string v0, "lantern_gojni"`
   — the bindings must load the renamed native library, never
   Mozilla's `libgojni.so`. (LML applied the identical patch.)
4. `smali assemble` the staging tree → `lantern-plugin.dex`.

Proof recorded in `build2129-leg-lantern.md`: per-class smali
diff of the official classes vs LML's plugin dex shows the 116
classes identical except that one string; Ember's assembled dex
round-trips (baksmali) smali-identical to the same tree. No
`com.lmlvpn.*` class is included.

## assets/lantern-bridge.dex — Ember's own bridge

Contents: `com.ralysnd.ember.lanternplugin.LanternEngine` (+ its
inner classes) — Ember's libbox `PlatformInterface` bridge,
source in this directory (`LanternEngine.java`), modelled on
LML's decompiled LanternEngine with Ember's Builder values and
per-app logic.

Rebuild: `javac` (JDK 21, `--cp android.jar:bindings.jar`,
where bindings.jar is the plugin dex converted with dex2jar)
then `d8 --min-api 26` → `lantern-bridge.dex`.

## Native libraries (jniLibs/arm64-v8a)

- `liblantern_gojni.so` — the official APK's
  `lib/arm64-v8a/libgojni.so`, byte-identical (sha256
  9166a5edb6169cf167fc4f7bdbc4095440f90913521b0e0a77013c6ebd99f593),
  renamed only. Its DT_NEEDED includes `libc++_shared.so`.
- `libc++_shared.so` — likewise byte-identical from the
  official APK (sha256
  cd61762848882a16c8244c964a6f396c0caa0b440588a210ce9cc4ab0e6d9f0c).

Both are pinned `keepDebugSymbols` in `build.gradle.kts` so AGP
never strips them.
