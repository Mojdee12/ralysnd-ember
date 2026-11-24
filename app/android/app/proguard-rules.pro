# Build 2028: the OpenVPN bridge resolves the Session
# callback methods BY NAME from native code (GetMethodID on
# configureTun / addAddress / addRoute / addDns /
# addSearchDomain / establishTun / onCoreEvent /
# onCoreTraffic / onCoreLog). R8 cannot see those calls, and
# in builds 2025-2027 it removed every one of them from the
# shipped dex as "unused" — the lookups then failed on device
# with a pending NoSuchMethodError and ART aborted the
# process inside run()'s preamble (the connect-start SIGABRT;
# research_notes/re-2028-openvpn/report.md). MLM's working app
# keeps exactly this surface; so do we. Any new native-called
# class or method must be added here AND to the packaged
# gate's dex contract check.
-keep class com.ralysnd.ember.OpenVpnNative { *; }
-keep class com.ralysnd.ember.OpenVpnService { *; }
-keep class com.ralysnd.ember.OpenVpnService$Session { *; }
-keepclassmembers class com.ralysnd.ember.OpenVpnService$Session { *; }
# The JNI entry points themselves (evaluate/create/run/stop/
# release/setBreadcrumbFile are `external fun` on the kept
# object; this is the standard belt-and-braces for them).
-keepclasseswithmembernames class * {
    native <methods>;
}

# Build 2091: the MLM transplant's AAR is back, so MLM's
# own keep rules for it return (its proguard-rules.pro,
# verbatim in substance): the gomobile library's classes
# are referenced by name from native code (the
# Tun2SocksJniLoader class is found by JNI_OnLoad's
# FindClass — R8 must not rename or strip it), and the
# recovered wrapper's dangling references (wf.c / w3.z /
# f0.a — classes the recovery renamed away) fail the build
# without the dontwarns below. R8's own generated rule for
# the 2091 build is -dontwarn f0.a; wf.c and w3.z are the
# other two names from the 2069-era set that shipped with
# this AAR in builds 2069–2088.
-keep class ca.psiphon.** { *; }
-keep class pg.** { *; }
-keep class psi.** { *; }
-dontwarn ca.psiphon.**
-dontwarn pg.**
-dontwarn psi.**
# Build 2123 (S-1): the recovery's "dangling references" are dangling
# no longer — libs/wf.jar now DEFINES wf.* and the R8 outline hosts
# the AAR references (see libs/wf-sources/PROVENANCE.md), so the 2091
# -dontwarn f0.a / wf.c / w3.z silencer rules are REMOVED and the
# bundled classes are kept whole instead (the AAR reaches them only
# through bytecode references R8 must not rename or strip):
-keep class wf.** { *; }
-keep class ug.b { *; }
-keep class a6.w0 { *; }
-keep class f0.a { *; }
-keep class w3.z { *; }
-keep class androidx.compose.foundation.gestures.d2 { *; }
-keep class org.telegram.ui.Cells.r3 { *; }
# Nothing else is warned off: with ug.b shimmed (PROVENANCE.md), the
# jar's classes reference no type outside wf.jar + the framework.
# The sidecar (build 2089) is retired from the start path;
# its fork and PsiphonBoxCore stay on disk as the documented
# fallback, so no dontwarn of theirs is needed here.
