allprojects {
    repositories {
        google()
        mavenCentral()
        // Build 2104: the WG Tunnel backend's runtime graph
        // includes libsu (com.github.topjohnwu.libsu), which
        // is published on JitPack only — WG Tunnel's own
        // settings declare this repository. The content
        // filter is Ember's addition: unscoped, Gradle asks
        // JitPack for every group, and its slow miss on the
        // io.flutter engine artifacts is a fatal timeout
        // rather than a 404.
        // Build 2104 (build-environment record): on this
        // machine Gradle's HTTP client hangs reading from
        // JitPack through the sandbox egress proxy (curl
        // fetches the same URLs in <1 s; four consecutive
        // builds died on the libsu POM read timeout, and a
        // timeout is fatal — Gradle does not fall through to
        // the next repository on a network error). The three
        // libsu core 6.0.0 artifacts are therefore seeded in
        // a local repository, downloaded once and verified
        // against the sha256 JitPack's own module metadata
        // publishes (core-6.0.0.aar:
        // a1ca5a8adb9ab11c42b71fc2d2a61b5a95cb4cdd06df0eb8c204c06813c2bb5b).
        // It is declared FIRST for the libsu group so the
        // seeded copy answers before JitPack is asked; the
        // content filter keeps it invisible to every other
        // group, and JitPack below remains the canonical
        // source on machines where it answers.
        maven {
            // Relative to this project's root (verification
            // iteration 2, L3): the seed lives in the Ember
            // workspace's toolchain directory, two levels
            // above src2 — never an absolute machine path.
            url = rootProject.layout.projectDirectory
                .dir("../../../toolchain/local-maven")
                .asFile
                .toURI()
            content { includeGroup("com.github.topjohnwu.libsu") }
        }
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.topjohnwu.libsu") }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
