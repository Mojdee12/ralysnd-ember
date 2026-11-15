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

# Build 2069 (Psiphon transplant): ralysnd's recovered
# tunnel-core v2.0.39 AAR carries three class references —
# wf.c, w3.z, f0.a — that exist ONLY in generic Signature
# attributes and throws clauses of the wrapper classes
# (ralysnd's own R8 renamed the types when it obfuscated
# ralysnd's app, and the recovery preserved those names).
# Verified before adding these rules: (1) NONE of the three
# classes is defined in ANY of ralysnd's shipped APK's six
# dexes — the working app runs without them; (2) javap -c
# over every referencing class shows ZERO bytecode
# instructions naming them (signatures/throws only — ART
# executes descriptors, not signatures); (3) the referencing
# methods (buildPsiphonConfig, parseRegionActivity,
# addUsableDNSServer) are wrapper-internal utilities that
# neither ralysnd's host nor Ember's host ever calls — both
# hosts build the core config themselves. These -dontwarn
# rules therefore replicate ralysnd's exact runtime
# conditions inside Ember's stricter R8; they hide nothing
# that can execute.
-dontwarn wf.c
-dontwarn w3.z
-dontwarn f0.a
