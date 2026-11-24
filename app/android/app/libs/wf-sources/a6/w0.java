package a6;

/**
 * Shim for the R8 outline host class {@code a6.w0} of MLM's build.
 *
 * The Psiphon AAR (ca.psiphon.*) and the bundled wf.* JSON classes call
 * the static string helpers below; in MLM's own APK they live in this
 * synthetic outline class. Only the methods actually referenced by the
 * AAR / wf classes are provided. Semantics were pinned instruction-for-
 * instruction from MLM 1.2.46's dex (jadx decompile of a6.w0, verified
 * against the call sites) — see ../PROVENANCE.md in this folder.
 *
 * This class is never called by Ember code; it exists so the bundled
 * MLM bytecode links exactly as it did inside MLM's app.
 */
public abstract class w0 {
    /** sb.append(j); sb.append(s); return sb.toString(); */
    public static String k(long j, String s, StringBuilder sb) {
        sb.append(j);
        sb.append(s);
        return sb.toString();
    }

    /** sb.append(s.substring(i)); return sb.toString(); */
    public static String m(String s, int i, StringBuilder sb) {
        sb.append(s.substring(i));
        return sb.toString();
    }

    /** return a + b + c; */
    public static String n(String a, String b, String c) {
        return a + b + c;
    }

    /** sb.append(i); sb.append(s); return sb.toString(); */
    public static String q(StringBuilder sb, int i, String s) {
        sb.append(i);
        sb.append(s);
        return sb.toString();
    }
}
