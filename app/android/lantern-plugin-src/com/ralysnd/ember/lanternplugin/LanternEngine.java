package com.ralysnd.ember.lanternplugin;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.IpPrefix;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.provider.Settings;
import android.system.Os;
import android.system.OsConstants;
import android.text.TextUtils;
import android.util.Log;

import java.io.File;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import lantern.io.libbox.ConnectionOwner;
import lantern.io.libbox.ExchangeContext;
import lantern.io.libbox.InterfaceUpdateListener;
import lantern.io.libbox.LocalDNSTransport;
import lantern.io.libbox.NetworkInterfaceIterator;
import lantern.io.libbox.Notification;
import lantern.io.libbox.RoutePrefix;
import lantern.io.libbox.RoutePrefixIterator;
import lantern.io.libbox.StringBox;
import lantern.io.libbox.StringIterator;
import lantern.io.libbox.TunOptions;
import lantern.io.libbox.WIFIState;
import lantern.io.mobile.Mobile;
import lantern.io.utils.FlutterEvent;
import lantern.io.utils.FlutterEventEmitter;
import lantern.io.utils.Opts;
import lantern.io.utils.PlatformInterface;
import lantern.io.utils.PrivateServerEventListener;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Ember's bridge to the official Lantern client's gomobile
 * core (build 2129), loaded from assets/lantern-plugin.dex by
 * LanternVpnService in the :lantern process — the plugin-dex
 * pattern (the bindings' go.* classes would collide with the
 * Mozilla core.aar's go.* in the main dex).
 *
 * Modelled on LML-VPN's LanternEngine (its initialize /
 * servers / connect shape and the libbox PlatformInterface
 * implementation), with Ember's own pieces kept verbatim:
 * the TUN Builder's address/route/DNS values are Ember's
 * Lantern values, and the per-app split choice is Ember's
 * Builder-level applyApps() logic (the Mobile split-tunnel
 * API is deliberately NOT adopted — its filter vocabulary is
 * undocumented and Ember's Builder choice is authoritative).
 *
 * The reflective surface LanternVpnService calls:
 * initialize, servers, connect, connected, selectedServer,
 * smartRouting, setSmartRouting, addPrivateServer,
 * deletePrivateServer, privateServerEvent, dupTunFd, close.
 */
public final class LanternEngine implements PlatformInterface, FlutterEventEmitter {
    private static final String TAG = "Ember-Lantern";

    private final VpnService service;
    private final ConnectivityManager cm;
    private volatile boolean ready;
    private volatile ParcelFileDescriptor tun;
    private volatile Network physical;
    private volatile ConnectivityManager.NetworkCallback callback;
    private volatile InterfaceUpdateListener listener;
    private final ExecutorService networkExecutor =
            Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, "Ember-Lantern-network");
                t.setDaemon(true);
                return t;
            });

    // Session values handed in by the service before connect
    // (the same extras the old CLI service took): they floor
    // the TUN the core asks for in openTun.
    private volatile boolean ipv6 = true;
    private volatile int mtu = 1500;
    private volatile String dns = "1.1.1.1";

    // The last private-server registration outcome, polled by
    // the service: "" until an event lands, then
    // "error|<words>" or "event|<words>".
    private volatile String privateEvent = "";

    // Build 2131: the tag the current session is pinned to
    // ("" = automatic), remembered at connect() so a core
    // service restart re-pins instead of falling back to the
    // public pool's automatic choice.
    private volatile String lastTag = "";

    public LanternEngine(VpnService vpnService) {
        this.service = vpnService;
        this.cm = (ConnectivityManager) vpnService.getSystemService(Context.CONNECTIVITY_SERVICE);
    }

    public void setSession(boolean ipv6Enabled, int mtuValue, String dnsServer) {
        this.ipv6 = ipv6Enabled;
        this.mtu = Math.max(1280, Math.min(1500, mtuValue));
        if (dnsServer != null && !dnsServer.isEmpty()) this.dns = dnsServer;
    }

    public void initialize() throws Exception {
        if (this.ready) return;
        // Build 2129: the gomobile core's own data layout —
        // <filesDir>/lantern with logs under it (the official
        // client's convention, LML's initialize verbatim).
        // The old CLI daemon's <filesDir>/lantern/v10 layout
        // is not read by this core.
        File data = new File(this.service.getFilesDir(), "lantern");
        File logs = new File(data, "logs");
        if ((!data.isDirectory() && !data.mkdirs()) ||
                (!logs.isDirectory() && !logs.mkdirs())) {
            throw new IllegalStateException("Lantern storage unavailable");
        }
        Opts opts = new Opts();
        opts.setDataDir(data.getAbsolutePath());
        opts.setLogDir(logs.getAbsolutePath());
        opts.setLogLevel("error");
        String deviceId = Settings.Secure.getString(
                this.service.getContentResolver(), "android_id");
        opts.setDeviceid(deviceId == null ? "" : deviceId);
        // The official client's own version string, exactly —
        // the core's config service rejects unknown client
        // versions (build 2064's lesson, learned with the CLI).
        opts.setAppVersion("10.0.5-beta.1");
        opts.setLocale(Locale.getDefault().toLanguageTag());
        opts.setTimeZone(TimeZone.getDefault().getID());
        opts.setEnv("prod");
        opts.setTelemetryConsent(false);
        opts.setPlatform(this);
        Mobile.startIPCServer(this, opts);
        try {
            Mobile.setupRadiance(opts, this);
            if (!Mobile.isRadianceConnected()) {
                throw new IllegalStateException("Lantern backend unavailable");
            }
            this.ready = true;
        } catch (Throwable th) {
            try {
                Mobile.closeIPCServer();
            } catch (Throwable ignored) {
            }
            if (th instanceof Exception) throw (Exception) th;
            throw new IllegalStateException("Lantern setup failed", th);
        }
        // Build 2129: heal through the real API what the 2128
        // settings-file write healed before — a past smart
        // start latched smart routing ON in the core's own
        // persisted settings; force it OFF at every init.
        // Smart routing stays OFF unless the user turns it on
        // (the Lantern page's toggle, DEFAULT OFF).
        try {
            Mobile.setSmartRoutingEnabled(false);
        } catch (Throwable ignored) {
        }
        // Ember's Builder-level per-app choice (openTun) is
        // authoritative; the core's own split tunneling must
        // not apply a second, persisted layer on top.
        try {
            Mobile.setSplitTunnelingEnabled(false);
        } catch (Throwable ignored) {
        }
    }

    public String servers() throws Exception {
        String available = Mobile.getAvailableServers();
        if (available == null || available.isEmpty()) available = "[]";
        JSONArray raw = new JSONArray(available);
        JSONArray out = new JSONArray();
        for (int i = 0; i < raw.length() && i < 500; i++) {
            JSONObject entry = raw.optJSONObject(i);
            if (entry == null) continue;
            String tag = entry.optString("tag", "");
            if (tag.isEmpty() || tag.length() > 256 ||
                    tag.matches(".*[\\x00-\\x1f].*")) continue;
            JSONObject location = entry.optJSONObject("location");
            if (location == null) location = new JSONObject();
            String code = location.optString("country_code", "")
                    .toUpperCase(Locale.ROOT);
            if (!code.matches("[A-Z]{2}")) code = "";
            out.put(new JSONObject()
                    .put("tag", tag)
                    // Build 2131: private servers (the core
                    // stores them with isLantern=false) are
                    // listed too — the picker marks them and
                    // they select like any other row. Up to
                    // 2130 this loop dropped them, so the
                    // owner's own server could never appear.
                    .put("isLantern", entry.optBoolean("isLantern", false))
                    .put("city", shortText(location.optString("city", "")))
                    .put("country", shortText(location.optString("country", "")))
                    .put("countryCode", code));
        }
        return out.toString();
    }

    private static String shortText(String s) {
        return s.length() > 80 ? s.substring(0, 80) : s;
    }

    public void connect(String tag) throws Exception {
        if (!this.ready) throw new IllegalStateException("Lantern is not initialized");
        // Build 2131: remember the pin for restartService().
        this.lastTag = tag == null ? "" : tag;
        if (tag == null || tag.isEmpty()) {
            Mobile.startVPN();
        } else {
            Mobile.connectToServer(tag);
        }
    }

    public boolean connected() {
        return this.ready && Mobile.isVPNConnected();
    }

    /** The core's own selected server (JSON string), or "". */
    public String selectedServer() {
        try {
            String json = Mobile.getSelectedServerJSON();
            return json == null ? "" : json;
        } catch (Throwable th) {
            return "";
        }
    }

    public boolean smartRouting() {
        try {
            return Mobile.isSmartRoutingEnabled();
        } catch (Throwable th) {
            return false;
        }
    }

    public void setSmartRouting(boolean on) {
        try {
            Mobile.setSmartRoutingEnabled(on);
        } catch (Throwable ignored) {
        }
    }

    /**
     * Registers the owner's private server through the
     * supported API (build 2129, replacing the 2127 H8
     * servers.json merge). Gomobile argument order, verified
     * in build2129-phase1-delta §1.7: ip, port (as a string),
     * accessToken, tag.
     */
    public void addPrivateServer(String ip, String port, String accessToken, String tag)
            throws Exception {
        if (!this.ready) throw new IllegalStateException("Lantern is not initialized");
        this.privateEvent = "";
        Mobile.addServerManagerInstance(ip, port, accessToken, tag,
                new PrivateServerEventListener() {
                    @Override
                    public void onError(String error) {
                        privateEvent = "error|" + (error == null ? "" : error);
                    }

                    @Override
                    public void onPrivateServerEvent(String event) {
                        privateEvent = "event|" + (event == null ? "" : event);
                    }

                    @Override
                    public void openBrowser(String url) {
                        privateEvent = "event|browser|" + (url == null ? "" : url);
                    }
                });
    }

    public void deletePrivateServer(String tag) {
        try {
            Mobile.deletePrivateServerByName(tag);
        } catch (Throwable ignored) {
        }
    }

    public String privateServerEvent() {
        return this.privateEvent;
    }

    /**
     * Build 2129 (kill switch, kept from 2127 H4/H5): the
     * bridge creates the TUN in openTun, so the service can
     * hold a duplicate of the TUN fd — if the session dies
     * unexpectedly with the kill switch on, the service
     * keeps its duplicate open (nothing reads it: traffic
     * blackholes instead of going direct) until the user
     * disconnects or reconnects.
     */
    public ParcelFileDescriptor dupTunFd() {
        ParcelFileDescriptor current = this.tun;
        if (current == null) return null;
        try {
            return current.dup();
        } catch (Throwable th) {
            return null;
        }
    }

    public void close() {
        if (this.ready) {
            try {
                Mobile.stopVPN();
            } catch (Throwable ignored) {
            }
            try {
                Mobile.closeIPCServer();
            } catch (Throwable ignored) {
            }
        }
        this.ready = false;
        stopMonitor();
        this.networkExecutor.shutdownNow();
        closeTun();
    }

    @Override
    public void sendEvent(FlutterEvent event) {
    }

    // ---- libbox PlatformInterface ----

    @Override
    public boolean usePlatformAutoDetectInterfaceControl() {
        return true;
    }

    @Override
    public void autoDetectInterfaceControl(int fd) throws Exception {
        if (fd < 0 || !this.service.protect(fd)) {
            throw new IllegalStateException("VPN socket protection failed");
        }
    }

    @Override
    public int openTun(TunOptions options) throws Exception {
        if (VpnService.prepare(this.service) != null) {
            throw new IllegalStateException("VPN permission missing");
        }
        VpnService.Builder builder = this.service.new Builder()
                .setSession("Ralysnd Ember")
                .setMtu(options.getMTU() > 0 ? options.getMTU() : this.mtu);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }
        boolean has4 = addresses(builder, options.getInet4Address());
        boolean has6 = addresses(builder, options.getInet6Address());
        // Ember's Lantern values floor the core's request:
        // when the core names no addresses, the TUN still
        // comes up with the addresses Ember has always used.
        if (!has4) {
            builder.addAddress("10.10.16.1", 30);
            has4 = true;
        }
        if (!has6 && this.ipv6) {
            builder.addAddress("fdfe:dcba:9876::1", 126);
            has6 = true;
        }
        if (options.getAutoRoute()) {
            StringBox dnsBox = options.getDNSServerAddress();
            String coreDns = dnsBox == null ? null : dnsBox.getValue();
            builder.addDnsServer(
                    coreDns != null && !coreDns.isEmpty() ? coreDns : this.dns);
            if (Build.VERSION.SDK_INT >= 33) {
                routes33(builder, options.getInet4RouteAddress(), false, has4, "0.0.0.0");
                routes33(builder, options.getInet6RouteAddress(), false, has6, "::");
                routes33(builder, options.getInet4RouteExcludeAddress(), true, false, "");
                routes33(builder, options.getInet6RouteExcludeAddress(), true, false, "");
            } else {
                routesLegacy(builder, options.getInet4RouteRange());
                routesLegacy(builder, options.getInet6RouteRange());
            }
        } else {
            builder.addDnsServer(this.dns);
            builder.addRoute("0.0.0.0", 0);
            if (this.ipv6) builder.addRoute("::", 0);
        }
        applyApps(builder);
        Network net = activePhysical();
        if (net != null) {
            this.service.setUnderlyingNetworks(new Network[]{net});
        }
        closeTun();
        ParcelFileDescriptor established = builder.establish();
        if (established == null) {
            throw new IllegalStateException("Cannot establish VPN TUN");
        }
        this.tun = established;
        return established.getFd();
    }

    /**
     * Which apps use the VPN — Ember's LanternVpnService
     * applyApps() logic, moved verbatim into openTun (build
     * 2129): the stored per-app choice every engine applies,
     * read from the same CoreService preferences.
     */
    private void applyApps(VpnService.Builder builder) {
        SharedPreferences prefs = this.service.getSharedPreferences(
                "vpn", Context.MODE_PRIVATE);
        String mode = prefs.getString("app_mode", "exclude");
        if ("include".equals(mode)) {
            Set<String> only = prefs.getStringSet("only_apps", Collections.emptySet());
            int added = 0;
            for (String pkg : only) {
                if (pkg.equals(this.service.getPackageName())) continue;
                try {
                    builder.addAllowedApplication(pkg);
                    added++;
                } catch (PackageManager.NameNotFoundException ignored) {
                    // Uninstalled since.
                }
            }
            if (added > 0) return;
            // The Only set resolved to nothing installed:
            // fall through to all-apps (the service journals
            // this case in its own log, as before).
            Log.w(TAG, "per-app Only set empty - all apps use the tunnel");
        }
        try {
            builder.addDisallowedApplication(this.service.getPackageName());
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        Set<String> bypass = prefs.getStringSet("bypass_apps", Collections.emptySet());
        for (String pkg : bypass) {
            if (pkg.equals(this.service.getPackageName())) continue;
            try {
                builder.addDisallowedApplication(pkg);
            } catch (PackageManager.NameNotFoundException ignored) {
                // Uninstalled since.
            }
        }
    }

    private static boolean addresses(VpnService.Builder builder, RoutePrefixIterator it) {
        boolean any = false;
        while (it != null && it.hasNext()) {
            RoutePrefix next = it.next();
            builder.addAddress(next.address(), next.prefix());
            any = true;
        }
        return any;
    }

    private static void routesLegacy(VpnService.Builder builder, RoutePrefixIterator it) {
        while (it != null && it.hasNext()) {
            RoutePrefix next = it.next();
            builder.addRoute(next.address(), next.prefix());
        }
    }

    private static void routes33(VpnService.Builder builder, RoutePrefixIterator it,
                                 boolean exclude, boolean hasFamily, String fallback)
            throws Exception {
        boolean any = false;
        while (it != null && it.hasNext()) {
            RoutePrefix next = it.next();
            IpPrefix prefix = new IpPrefix(InetAddress.getByName(next.address()), next.prefix());
            if (exclude) {
                builder.excludeRoute(prefix);
            } else {
                builder.addRoute(prefix);
            }
            any = true;
        }
        if (!any && hasFamily && !exclude) {
            builder.addRoute(new IpPrefix(InetAddress.getByName(fallback), 0));
        }
    }

    private void closeTun() {
        ParcelFileDescriptor current = this.tun;
        this.tun = null;
        if (current != null) {
            try {
                current.close();
            } catch (Exception ignored) {
            }
        }
    }

    @Override
    public void postServiceClose() {
        closeTun();
    }

    @Override
    public void restartService() throws Exception {
        Mobile.stopVPN();
        // Build 2131: a restart re-pins to the session's
        // server; up to 2130 it always restarted automatic,
        // silently dropping a private/public pin.
        if (this.lastTag.isEmpty()) {
            Mobile.startVPN();
        } else {
            Mobile.connectToServer(this.lastTag);
        }
    }

    private Network activePhysical() {
        Network active = this.cm.getActiveNetwork();
        if (isPhysical(active)) {
            this.physical = active;
            return active;
        }
        Network kept = this.physical;
        if (isPhysical(kept)) return kept;
        for (Network n : this.cm.getAllNetworks()) {
            if (isPhysical(n)) {
                this.physical = n;
                return n;
            }
        }
        this.physical = null;
        return null;
    }

    private boolean isPhysical(Network network) {
        if (network == null) return false;
        NetworkCapabilities caps = this.cm.getNetworkCapabilities(network);
        return caps != null &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN);
    }

    private static NetworkInterface javaInterface(String name) {
        try {
            return NetworkInterface.getByName(name);
        } catch (Exception e) {
            return null;
        }
    }

    private static int interfaceIndex(String name, NetworkInterface ni) throws Exception {
        if (ni != null && ni.getIndex() > 0) return ni.getIndex();
        if (Build.VERSION.SDK_INT >= 26) return Os.if_nametoindex(name);
        return -1;
    }

    private void notifyDefault() {
        final InterfaceUpdateListener current = this.listener;
        if (current == null) return;
        this.networkExecutor.execute(() -> deliverDefault(current));
    }

    private void deliverDefault(InterfaceUpdateListener target) {
        for (int i = 0; i < 10; i++) {
            try {
                if (this.listener != target) return;
                Network net = activePhysical();
                if (net == null) {
                    if (this.listener == target) {
                        target.updateDefaultInterface("", -1, false, false);
                    }
                    return;
                }
                LinkProperties props = this.cm.getLinkProperties(net);
                String name = props == null ? null : props.getInterfaceName();
                if (name != null && !name.isEmpty()) {
                    int index = -1;
                    try {
                        index = interfaceIndex(name, javaInterface(name));
                    } catch (Exception ignored) {
                    }
                    if (index > 0) {
                        this.service.setUnderlyingNetworks(new Network[]{net});
                        if (this.listener == target) {
                            target.updateDefaultInterface(name, index, false, false);
                        }
                        return;
                    }
                }
                if (i < 9) Thread.sleep(100L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (Throwable th) {
                Log.w(TAG, "Default interface update failed", th);
                return;
            }
        }
        Log.w(TAG, "Unable to resolve the default interface");
    }

    @Override
    public synchronized void startDefaultInterfaceMonitor(InterfaceUpdateListener listener)
            throws Exception {
        stopMonitor();
        this.listener = listener;
        this.callback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                notifyDefault();
            }

            @Override
            public void onLost(Network network) {
                if (network.equals(physical)) physical = null;
                notifyDefault();
            }

            @Override
            public void onLinkPropertiesChanged(Network network, LinkProperties props) {
                notifyDefault();
            }

            @Override
            public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                notifyDefault();
            }
        };
        try {
            this.cm.registerNetworkCallback(new NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build(), this.callback);
            notifyDefault();
        } catch (RuntimeException e) {
            stopMonitor();
            throw e;
        }
    }

    @Override
    public synchronized void closeDefaultInterfaceMonitor(InterfaceUpdateListener listener) {
        stopMonitor();
    }

    private synchronized void stopMonitor() {
        ConnectivityManager.NetworkCallback cb = this.callback;
        this.callback = null;
        this.listener = null;
        if (cb != null) {
            try {
                this.cm.unregisterNetworkCallback(cb);
            } catch (Exception ignored) {
            }
        }
    }

    @Override
    public NetworkInterfaceIterator getInterfaces() throws Exception {
        ArrayList<lantern.io.libbox.NetworkInterface> out = new ArrayList<>();
        for (Network network : this.cm.getAllNetworks()) {
            if (!isPhysical(network)) continue;
            LinkProperties props = this.cm.getLinkProperties(network);
            NetworkCapabilities caps = this.cm.getNetworkCapabilities(network);
            if (props == null || props.getInterfaceName() == null || caps == null) continue;
            String name = props.getInterfaceName();
            try {
                NetworkInterface ni = javaInterface(name);
                int index = interfaceIndex(name, ni);
                if (index <= 0) continue;
                lantern.io.libbox.NetworkInterface entry = new lantern.io.libbox.NetworkInterface();
                int mtuValue = ni != null ? ni.getMTU()
                        : Build.VERSION.SDK_INT >= 29 ? props.getMtu() : 0;
                entry.setName(name);
                entry.setIndex(index);
                entry.setMTU(mtuValue <= 0 ? 1500 : mtuValue);
                ArrayList<String> addresses = new ArrayList<>();
                for (LinkAddress linkAddress : props.getLinkAddresses()) {
                    InetAddress address = linkAddress.getAddress();
                    if (address instanceof Inet6Address) {
                        address = Inet6Address.getByAddress(address.getAddress());
                    }
                    addresses.add(address.getHostAddress() + "/" + linkAddress.getPrefixLength());
                }
                ArrayList<String> dnsServers = new ArrayList<>();
                for (InetAddress dnsServer : props.getDnsServers()) {
                    dnsServers.add(dnsServer.getHostAddress());
                }
                int flags = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        ? OsConstants.IFF_UP | OsConstants.IFF_RUNNING : 0;
                if (ni != null) {
                    if (ni.isLoopback()) flags |= OsConstants.IFF_LOOPBACK;
                    if (ni.isPointToPoint()) flags |= OsConstants.IFF_POINTOPOINT;
                    if (ni.supportsMulticast()) flags |= OsConstants.IFF_MULTICAST;
                } else {
                    flags |= OsConstants.IFF_MULTICAST;
                }
                entry.setAddresses(new Strings(addresses));
                entry.setDNSServer(new Strings(dnsServers));
                entry.setFlags(flags);
                entry.setMetered(!caps.hasCapability(11)); // NET_CAPABILITY_NOT_METERED
                int type;
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    type = 0;
                } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                    type = 1;
                } else if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
                    type = 2;
                } else {
                    type = 3;
                }
                entry.setType(type);
                out.add(entry);
            } catch (Exception e) {
                Log.w(TAG, "Skipping unavailable interface " + name, e);
            }
        }
        return new Interfaces(out);
    }

    @Override
    public ConnectionOwner findConnectionOwner(int protocol, String source, int sourcePort,
                                               String destination, int destinationPort)
            throws Exception {
        if (Build.VERSION.SDK_INT < 29) {
            throw new UnsupportedOperationException("connection owner requires Android 10");
        }
        int uid = this.cm.getConnectionOwnerUid(protocol,
                new InetSocketAddress(source, sourcePort),
                new InetSocketAddress(destination, destinationPort));
        if (uid < 0) throw new IllegalStateException("Connection owner unavailable");
        ConnectionOwner owner = new ConnectionOwner();
        owner.setUserId(uid);
        String name = this.service.getPackageManager().getNameForUid(uid);
        owner.setUserName(name == null ? "" : name);
        String[] packages = this.service.getPackageManager().getPackagesForUid(uid);
        ArrayList<String> list = new ArrayList<>();
        if (packages != null) Collections.addAll(list, packages);
        owner.setAndroidPackageNames(new Strings(list));
        return owner;
    }

    @Override
    public LocalDNSTransport localDNSTransport() {
        return new LocalDNSTransport() {
            @Override
            public boolean raw() {
                return false;
            }

            @Override
            public void exchange(ExchangeContext context, byte[] bytes) {
                context.errorCode(2);
            }

            @Override
            public void lookup(ExchangeContext context, String type, String domain) {
                try {
                    Network net = activePhysical();
                    if (net == null) throw new IllegalStateException("No underlying network");
                    ArrayList<String> found = new ArrayList<>();
                    for (InetAddress address : net.getAllByName(domain)) {
                        boolean v6 = address instanceof Inet6Address;
                        if (type.endsWith("4") && v6) continue;
                        if (type.endsWith("6") && !v6) continue;
                        found.add(address.getHostAddress());
                    }
                    if (found.isEmpty()) {
                        context.errorCode(3);
                    } else {
                        context.success(TextUtils.join("\n", found));
                    }
                } catch (Exception e) {
                    context.errorCode(3);
                }
            }
        };
    }

    @Override
    public boolean includeAllNetworks() {
        return false;
    }

    @Override
    public boolean underNetworkExtension() {
        return false;
    }

    @Override
    public boolean useProcFS() {
        return Build.VERSION.SDK_INT < 29;
    }

    @Override
    public void clearDNSCache() {
    }

    @Override
    public WIFIState readWIFIState() {
        return null;
    }

    @Override
    public void sendNotification(Notification notification) {
    }

    @Override
    public StringIterator systemCertificates() {
        return new Strings(Collections.emptyList());
    }

    private static final class Strings implements StringIterator {
        private final Iterator<String> it;
        private final List<String> list;

        Strings(List<String> list) {
            this.list = list;
            this.it = list.iterator();
        }

        @Override
        public boolean hasNext() {
            return this.it.hasNext();
        }

        @Override
        public int len() {
            return this.list.size();
        }

        @Override
        public String next() {
            return this.it.hasNext() ? this.it.next() : "";
        }
    }

    private static final class Interfaces implements NetworkInterfaceIterator {
        private final Iterator<lantern.io.libbox.NetworkInterface> it;

        Interfaces(List<lantern.io.libbox.NetworkInterface> list) {
            this.it = list.iterator();
        }

        @Override
        public boolean hasNext() {
            return this.it.hasNext();
        }

        @Override
        public lantern.io.libbox.NetworkInterface next() {
            return this.it.hasNext() ? this.it.next() : null;
        }
    }
}
