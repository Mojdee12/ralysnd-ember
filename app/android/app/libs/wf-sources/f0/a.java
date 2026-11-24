package f0;

/**
 * Shim for the R8 outline host class {@code f0.a} of the Psiphon AAR's
 * own library build. The AAR's ca.psiphon / pg classes call the two
 * static string helpers below. MLM's app build has an unrelated f0.a
 * (different R8 run, different outline contents), so these semantics
 * were pinned from the AAR's call sites plus the identical source
 * expressions in MLM's app build (pg.Seq$Ref: RuntimeException text
 * built as prefix + refnum; PsiphonTunnel.addUsableDNSServer:
 * hostAddress + "%" + interfaceName). See ../PROVENANCE.md.
 */
public abstract class a {
    /** return s + i;  (message prefix, then the number) */
    public static String h(int i, String s) {
        return s + i;
    }

    /** return a + b + c; */
    public static String l(String a, String b, String c) {
        return a + b + c;
    }
}
