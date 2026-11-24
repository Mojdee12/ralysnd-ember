package org.telegram.ui.Cells;

/**
 * Shim for the R8 outline host class {@code org.telegram.ui.Cells.r3}
 * of MLM's build. Only g() is referenced (from wf.c); semantics pinned
 * from MLM 1.2.46's dex (jadx decompile of r3):
 * g(i, i2, str) == str.substring(i2, str.length() - i).
 * See libs/wf-sources/PROVENANCE.md.
 */
public class r3 {
    public static String g(int i, int i2, String str) {
        return str.substring(i2, str.length() - i);
    }
}
