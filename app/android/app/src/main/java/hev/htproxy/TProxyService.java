package hev.htproxy;

/**
 * JNI holder for libhev-socks5-tunnel.so — hev-socks5-tunnel
 * 2.17.1 (heiher, MIT), vendored at native-src/hev-socks5-tunnel
 * and NDK-built in build 2155 (the 2153 bridge swap).
 *
 * The native side (src/hev-jni.c) registers its natives on
 * exactly this class in JNI_OnLoad — PKGNAME/CLSNAME default to
 * hev/htproxy/TProxyService — so the package, the class name,
 * the method names and the signatures below are a contract
 * with the vendored .so. Do not rename or re-shape them.
 *
 * Semantics (hev-jni.c, read firsthand in the 2153 terrain
 * audit): start spawns hev's own pthread running the tunnel
 * and returns at once; it refuses (false) while an instance
 * is already running, WITHOUT consuming the fd. Stop signals
 * quit and joins the thread synchronously — when it returns,
 * the tunnel is fully dead. The fd handed to start is closed
 * by the native side on teardown, so callers pass a dup (see
 * HevTunManager).
 */
public final class TProxyService {

    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    private TProxyService() {
    }

    public static native boolean TProxyStartService(String configPath, int fd);

    public static native boolean TProxyStopService();

    public static native boolean TProxyIsRunning();

    public static native long[] TProxyGetStats();
}
