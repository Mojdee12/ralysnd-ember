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
    compileSdk = flutter.compileSdkVersion
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
        minSdk = maxOf(24, flutter.minSdkVersion)
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
    // The Psiphon tunnel core — build 2069 TRANSPLANT: this AAR
    // is ralysnd's complete Psiphon stack, byte-exact (their
    // psiphontunnel-2.0.39-ns-recovered.aar: the stock
    // tunnel-core v2.0.39 wrapper + libpgjni.so, gomobile
    // runtime renamed go/ -> pg/ and libgojni -> libpgjni so it
    // coexists with core.aar's gomobile runtime). It replaces
    // Ember's rebuilt v2.0.42 + fork-patch AAR wholesale — see
    // BUILD-LOG-2.md, build 2069. Do not rebuild this from the
    // fork tree without a device-proven reason.
    implementation(files("libs/psiphon.aar"))
}
