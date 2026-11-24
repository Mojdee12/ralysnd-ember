import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key, from android/key.properties (never in Git: CI writes it
// from the repository's secrets). storeFile, storePassword, keyAlias,
// keyPassword.
val releaseKey = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "com.ralysnd.ember"
    // Build 2104: compileSdk 37 — the WG Tunnel backend
    // AARs (backend-android, backend-android-jni, and the
    // androidx.core 1.19.1 they pull) declare
    // minCompileSdk 37, and checkReleaseAarMetadata refuses
    // to link them into an app compiled against 36. This is
    // a compile-time floor only: targetSdk stays at
    // Flutter's value below, so no runtime behavior changes
    // (and minSdk's own story is the named 24→26 loss).
    compileSdk = 37
    // The NDK installed here (Flutter's default, 28.x, is not).
    ndkVersion = "30.0.16248370"

    // The native libraries (the Go core, Flutter's engine, the app's code)
    // are compressed inside the APK, as zip files are: a third of the
    // download (33 MB to about 14 MB for arm64). Android unpacks them when it
    // installs the app, which takes a little more room on the phone. The
    // files themselves do not change.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Build 2069 (Psiphon transplant): libpgjni.so
            // ships BYTE-EXACT as ralysnd ships it — ralysnd's
            // APK carries the AAR's lib unstripped (sha256
            // 4f625112… in both), while AGP's strip task trims
            // 16 bytes and breaks the identity the transplant
            // exists to prove. Keep its symbols so the packaged
            // bytes equal ralysnd's exactly.
            keepDebugSymbols += "**/libpgjni.so"
            // Build 2072: the DNSTT and wstunnel helpers are
            // standalone executables staged as .so; they ship
            // byte-exact as vendored (engines/dnstt,
            // engines/wstunnel) so the packaged bytes can be
            // hash-verified against the recorded artifacts.
            keepDebugSymbols += "**/libdnstt.so"
            keepDebugSymbols += "**/libwstunnel.so"
            // Build 2075 sidecars: byte-exact like the 2072
            // pair (see the libxray note above).
            keepDebugSymbols += "**/libsingbox.so"
            keepDebugSymbols += "**/libmieru.so"
            keepDebugSymbols += "**/libdnscrypt.so"
            // Build 2129 (Lantern gomobile swap): the official
            // Lantern v10.0.5-beta.1 libgojni.so, renamed, and
            // its libc++ runtime ship BYTE-EXACT as extracted
            // from the official APK (trust gate:
            // build2129-phase0.md) — no strip.
            keepDebugSymbols += "**/liblantern_gojni.so"
            keepDebugSymbols += "**/libc++_shared.so"
            // Build 2129 (Leg 3): the Senpai scanner binary,
            // vendored byte-exact from the LML APK extract
            // (sha256 4ca1a8d9…; MIT, matinsenpai/senpaiscanner
            // — see SenpaiCore.kt) — no strip, so the packaged
            // bytes stay hash-verifiable against the extract.
            keepDebugSymbols += "**/libsenpai_lml.so"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ralysnd.ember"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The core's aar is built for API 24 (gomobile bind -androidapi 24).
        // Build 2104: the floor rises to 26 — the WG Tunnel
        // backend (com.wgtunnel:backend 1.10.1, the AmneziaWG
        // engine since this build) requires minSdk 26. Named
        // loss, recorded in BUILD-LOG-2.md: devices on API
        // 24/25 (Android 7.x) can no longer install Ember.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (!releaseKey.isEmpty) {
                storeFile = file(releaseKey.getProperty("storeFile"))
                storePassword = releaseKey.getProperty("storePassword")
                keyAlias = releaseKey.getProperty("keyAlias")
                keyPassword = releaseKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Signed with the release key; without key.properties (a fork,
            // a machine without the key) with the debug key, which cannot
            // update an installed release.
            signingConfig = signingConfigs.getByName(if (releaseKey.isEmpty) "debug" else "release")
            // Build 2028: the OpenVPN bridge resolves its Session
            // callbacks by name from native code; R8 must not strip
            // or rename them (it did in builds 2025-2027, removing
            // all nine — the connect-start SIGABRT; see
            // research_notes/re-2028-openvpn/report.md).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The Go core: `gomobile bind -target=android -androidapi 24
    // -o app/android/app/libs/core.aar ./mobile` in core/ (see app/README.md).
    implementation(files("libs/core.aar"))
    // Build 2091: the Psiphon core is the ralysnd app's AAR
    // again (psiphontunnel-2.0.39-ns, sha256 426c0fda… —
    // the MLM transplant; see PsiphonVpnService and
    // mlm-psiphon-full-analysis.md §9). The 2089/2090
    // libpsiphonbox.so sidecar is retired from the start path
    // (its vendored build stays at
    // engines/psiphonbox/build-android/ as the documented
    // fallback); libs/psiphon.aar is restored.
    implementation(files("libs/psiphon.aar"))
    // Build 2123 (S-1): the classes the Psiphon AAR references but
    // does not contain — the wf.* JSON mini-library (extracted
    // byte-faithful from MLM 1.2.46) plus the R8 outline-host shims
    // and the ug.b NULL-sentinel shim. Without these, every Psiphon
    // start died with NoClassDefFoundError: Lwf/c (plan
    // psiphon-chain-fix-plan.md §3/S-1). Provenance and rebuild
    // steps: libs/wf-sources/PROVENANCE.md.
    implementation(files("libs/wf.jar"))
    // Build 2075: FileProvider for the in-app updater's install
    // intent. Pinned to the version in the offline Gradle cache
    // (1.13.1) — no new downloads.
    implementation("androidx.core:core-ktx:1.13.1")
    // Build 2104: the WireGuard/AmneziaWG engine is WG Tunnel's
    // backend (github.com/wgtunnel/core, MIT), replacing the
    // hand-built libwg-go.so bridge over amneziawg-go v1.0.4
    // (builds 2040–2103). The backend's Go device is
    // amneziawg-go v3; its parser and Ember's state reads are
    // versioned together by the same project, which is the
    // property the old path lacked (see BUILD-LOG-2.md).
    // backend-android-jni carries the native libraries
    // (libam-go.so / libam.so / libam-quick.so); parser is the
    // .conf / ActiveConfig parser. Transitives (coroutines,
    // kermit, lifecycle-service, hevtunnel, libsu) resolve
    // from Maven Central / Google like everything else here.
    implementation("com.wgtunnel:backend:1.10.1")
    implementation("com.wgtunnel:backend-android-jni:1.10.1")
    implementation("com.wgtunnel:parser:1.10.1")
    // Build 2104: WgTunnelEngine.kt drives the backend's
    // suspend API from coroutines and writes its log through
    // kermit — both are the backend's own versions, declared
    // here because Ember code now names them directly.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("co.touchlab:kermit:2.2.0")
}
