package w3;

/**
 * Shim for the R8 outline host class {@code w3.z} of the Psiphon AAR's
 * own library build. Called only from ca.psiphon.PsiphonTunnel:
 * d() seeds the StringBuilder for the Exception(message, cause)
 * message, g() concatenates a diagnostic message with its suffix.
 * Semantics pinned from the AAR's call sites (the builder returned by
 * d() is appended the cause message and stringified; g()'s result is
 * the diagnostic string). See ../PROVENANCE.md.
 */
public final class z {
    /** return new StringBuilder(a).append(b); */
    public static StringBuilder d(String a, String b) {
        return new StringBuilder(a).append(b);
    }

    /** return a + b; */
    public static String g(String a, String b) {
        return a + b;
    }
}
