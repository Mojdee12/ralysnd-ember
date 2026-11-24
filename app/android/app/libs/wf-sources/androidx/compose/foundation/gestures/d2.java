package androidx.compose.foundation.gestures;

/**
 * Shim for the R8 outline host class
 * {@code androidx.compose.foundation.gestures.d2} of MLM's build.
 * Only the two static string helpers referenced by the bundled wf.*
 * JSON classes (and the Psiphon AAR) are provided; semantics pinned
 * from MLM 1.2.46's dex (jadx decompile of d2). See ../../PROVENANCE.md
 * (in libs/wf-sources).
 */
public abstract class d2 {
    /** return a + i + b; */
    public static String p(int i, String a, String b) {
        return a + i + b;
    }

    /** return new StringBuilder(s); */
    public static StringBuilder u(String s) {
        return new StringBuilder(s);
    }
}
