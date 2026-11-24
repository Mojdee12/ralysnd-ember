package ug;

/**
 * Shim for {@code ug.b} — the class wf.c's static NULL sentinel is an
 * instance of ({@code public static final ug.b c = new ug.b(2);}).
 *
 * In MLM's build ug.b is an R8 synthetic merged class: one class body
 * keyed by the int variant field {@code a}, holding several unrelated
 * tiny classes (an audio resampler, a dummy MediaDrm, and org.json's
 * JSONObject.NULL sentinel as variant 2). Only variant 2 is ever
 * constructed on the Psiphon path — by wf.c's <clinit> — and the only
 * operations wf.* / the AAR ever perform on it are the ones below
 * (verified by a full reference sweep: exactly one Lug/b; reference
 * exists in the whole AAR+wf closure, the field in wf.c).
 *
 * Extracting MLM's ug.b byte-faithful was rejected: it implements
 * ug.a / vg.a / z3.v, and ug.a's <clinit> instantiates further merged
 * classes (xa.e, ug.c, ug.d) that belong to a media library Ember does
 * not ship — a load-time cascade for a 4-method sentinel. This shim
 * reproduces variant 2's semantics exactly as jadx recovered them from
 * MLM 1.2.46's dex:
 *   equals:   variant 2 -> (obj == null || obj == this)
 *   hashCode: variant 2 -> 0
 *   toString: variant 2 -> "null"
 *   clone:    variant 2 -> this
 * Other variants fall back to Object defaults, as in MLM's class.
 * See libs/wf-sources/PROVENANCE.md.
 */
public final class b {
    public final int a;

    public b(int i) {
        this.a = i;
    }

    @Override
    public boolean equals(Object obj) {
        if (this.a == 2) {
            return obj == null || obj == this;
        }
        return super.equals(obj);
    }

    @Override
    public int hashCode() {
        if (this.a == 2) {
            return 0;
        }
        return super.hashCode();
    }

    @Override
    public String toString() {
        if (this.a == 2) {
            return "null";
        }
        return super.toString();
    }

    @Override
    public Object clone() {
        if (this.a == 2) {
            return this;
        }
        try {
            return super.clone();
        } catch (CloneNotSupportedException e) {
            throw new RuntimeException(e);
        }
    }
}
