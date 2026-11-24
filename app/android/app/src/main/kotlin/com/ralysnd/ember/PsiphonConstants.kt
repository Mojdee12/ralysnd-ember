package com.ralysnd.ember

/**
 * The Psiphon engine's bootstrap identity: the propagation channel,
 * sponsor and server-list trust anchors the tunnel core needs before
 * it can find any server.
 *
 * Build 2091 (the MLM transplant): the identity set is now the
 * ralysnd (MLM) app's — PropagationChannelId FFFFFFFFFFFFFFFF,
 * SponsorId 1111111111111111, ClientVersion "1" — because the whole
 * Psiphon implementation (config builder, ladder, data roots) is
 * MLM's, ported as one unit (see PsiphonVpnService and
 * mlm-psiphon-full-analysis.md §3/§9). Builds 2069–2088 carried the
 * official Android app's set (92AACC5BABE0944C / 40001BC527D3D099 /
 * "509"); the swap is a one-block change if a device A/B ever wants
 * the official set back (risk R8 in the analysis).
 *
 * The three trust keys below did NOT change: they are byte-identical
 * between the official app and MLM (the analysis verified this), and
 * the server-list URLs are the same channel (iohq-waa4-q4dt) in both.
 *
 * Note: Psiphon's current terms allow the network to be used through
 * official clients (partnership-only embedding). This integration
 * exists at the app owner's explicit instruction, with that
 * restriction known and accepted.
 */
object PsiphonConstants {
    const val SOCKS_PORT = 11808
    const val HTTP_PORT = 11809

    // Build 2091: MLM's identity set (see the header).
    const val CLIENT_VERSION = "1"
    const val PROPAGATION_CHANNEL_ID = "FFFFFFFFFFFFFFFF"
    const val SPONSOR_ID = "1111111111111111"
    const val REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY = "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="
    const val SERVER_ENTRY_SIGNATURE_PUBLIC_KEY = "sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA="

    /** AssetManager path (Flutter asset) of MLM's embedded server
     *  list — build 2091's bootstrap floor, handed to the core as a
     *  string at every start (MLM's server_entries.txt: 493 hex
     *  lines). The official app's list (embedded_servers.txt, builds
     *  2069–2090) stays bundled as the documented A/B asset; nothing
     *  on the start path reads it any more. */
    const val SERVER_ENTRIES_ASSET = "flutter_assets/assets/psiphon/server_entries.txt"

    /** AssetManager path (Flutter asset) of the official app's
     *  embedded server list — the A/B asset (see above). */
    const val EMBEDDED_SERVERS_ASSET = "flutter_assets/assets/psiphon/embedded_servers.txt"

    // ---- Server-list freshness, anti-hijack DNS, ladder ----
    //
    // Values provenance: the official client's own remote-server-list
    // locations (channel path iohq-waa4-q4dt), as used by the ralysnd
    // app's Psiphon host (PsiphonUrlList in TunnelVpnService.kt) and
    // verified against this file's signature keys above — the RSL
    // signature key and server-entry key here are byte-identical to
    // the ones ralysnd ships, so lists fetched from these hosts
    // verify against them. Each URL entry is the core's expected
    // {URL: base64(url), OnlyAfterAttempts, SkipVerify} object;
    // PsiphonVpnService encodes them.

    /** Obfuscation key for the obfuscated server list. */
    const val EXCHANGE_OBFUSCATION_KEY = "DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU="

    /** (url, onlyAfterAttempts, skipVerify) for RemoteServerListURLs. */
    val REMOTE_SERVER_LIST_URLS: List<Triple<String, Int, Boolean>> = listOf(
        Triple("https://s3.amazonaws.com/psiphon/web/iohq-waa4-q4dt/server_list_compressed", 0, false),
        Triple("https://www.gpallthingsnumberweather.com/web/iohq-waa4-q4dt/server_list_compressed", 2, true),
        Triple("https://www.storagejsstrategiesfabulous.com/web/iohq-waa4-q4dt/server_list_compressed", 2, true),
        Triple("https://www.diamondberlingamerplanet.com/web/iohq-waa4-q4dt/server_list_compressed", 2, true),
    )

    /** (url, onlyAfterAttempts, skipVerify) for ObfuscatedServerListRootURLs. */
    val OBFUSCATED_SERVER_LIST_ROOT_URLS: List<Triple<String, Int, Boolean>> = listOf(
        Triple("https://s3.amazonaws.com/psiphon/web/iohq-waa4-q4dt/osl", 0, false),
        Triple("https://www.gpallthingsnumberweather.com/web/iohq-waa4-q4dt/osl", 2, true),
        Triple("https://www.storagejsstrategiesfabulous.com/web/iohq-waa4-q4dt/osl", 2, true),
        Triple("https://www.diamondberlingamerplanet.com/web/iohq-waa4-q4dt/osl", 2, true),
    )

    /**
     * Anti-DNS-hijack resolvers (MLM's PSIPHON_ALTERNATE_DNS):
     * open resolvers on non-standard ports, preferred at probability
     * 1.0 — born from a field log where every dial died on a hijacked
     * system resolver ("checkDNSAnswerIP: IP is bogon").
     */
    val DNS_PREFERRED_ALTERNATE_SERVERS: List<String> = listOf(
        "208.67.222.222:5353",
        "9.9.9.9:9953",
        "208.67.220.220:5353",
    )

    /** Fronting provider IDs for DNSResolverPreresolvedIPAddressCIDRs
     *  (MLM's PsiphonCleanIps provider table). */
    const val FRONTING_PROVIDER_AKAMAI = "BACEC04E64813F2B"
    const val FRONTING_PROVIDER_FASTLY = "089D05B86ACE8D3B"

    /** The FRONTED protocol family (MLM PsiphonMethods.FRONTED). */
    val FRONTED_PROTOCOLS: List<String> = listOf(
        "FRONTED-MEEK-OSSH",
        "FRONTED-MEEK-HTTP-OSSH",
        "FRONTED-MEEK-QUIC-OSSH",
    )

    /** TCP-only protocols that can ride an upstream proxy
     *  (MLM PsiphonMethods.PROTOCOLS_CHAINABLE). */
    val CHAINABLE_PROTOCOLS: List<String> = listOf(
        "FRONTED-MEEK-OSSH",
        "FRONTED-MEEK-HTTP-OSSH",
        "TLS-OSSH",
        "UNFRONTED-MEEK-HTTPS-OSSH",
        "UNFRONTED-MEEK-OSSH",
        "SHADOWSOCKS-OSSH",
        "OSSH",
        "SSH",
    )

    /** Protocols that prove a DIRECT tunnel for winner attribution
     *  (MLM PsiphonMethods.PROTOCOLS_DIRECT). Detection only —
     *  never written into a config as a limit. */
    val DIRECT_PROTOCOLS: List<String> = listOf(
        "QUIC-OSSH",
        "TLS-OSSH",
        "UNFRONTED-MEEK-HTTPS-OSSH",
        "UNFRONTED-MEEK-OSSH",
        "SHADOWSOCKS-OSSH",
        "CONJURE-OSSH",
        "OSSH",
        "SSH",
    )

    // ---- Build 2129 (Leg 2): the Shiro bootstrap identity set ----
    //
    // The public bootstrap published with the Shirokhorshid
    // Android release (Shirokhorshid/MehrON, GPL-3.0-or-later):
    // its own propagation channel, sponsor, client version,
    // server-list locations and trust anchors, adopted
    // WHOLESALE as one set — the diff against the MLM set above
    // (build2129-leg-psiphon.md) shows the channel, sponsor,
    // client version and both URL lists DIFFER while the two
    // signature keys and the exchange obfuscation key are the
    // SAME values. Nothing here is ever mixed with the MLM set:
    // PsiphonVpnService picks one set or the other per start,
    // behind the DEFAULT-OFF Shiro bootstrap setting. The
    // embedded entries that pair with this set are
    // assets/psiphon/server_list_shiro.dat (2,434 entries,
    // format-identical to server_entries.txt: hex lines whose
    // decoded form is the same prefix + ServerEntry JSON).

    const val SHIRO_CLIENT_VERSION = "453"
    const val SHIRO_PROPAGATION_CHANNEL_ID = "EE0B7486ACAE75AA"
    const val SHIRO_SPONSOR_ID = "07D1ACD69B3AC7A2"
    const val SHIRO_REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY = "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="
    const val SHIRO_SERVER_ENTRY_SIGNATURE_PUBLIC_KEY = "sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA="
    const val SHIRO_EXCHANGE_OBFUSCATION_KEY = "DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU="

    /** (url, onlyAfterAttempts, skipVerify) for the Shiro
     *  set's RemoteServerListURLs (S3 locations only, one
     *  channel per location, all first-attempt + verified). */
    val SHIRO_REMOTE_SERVER_LIST_URLS: List<Triple<String, Int, Boolean>> = listOf(
        Triple("https://s3.amazonaws.com/psiphon/web/frh2-29ub-lhe0/server_list_compressed", 0, false),
        Triple("https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed", 0, false),
        Triple("https://s3.amazonaws.com/psiphon/web/yttm-zeis-pjjd/server_list_compressed", 0, false),
    )

    /** (url, onlyAfterAttempts, skipVerify) for the Shiro
     *  set's ObfuscatedServerListRootURLs. */
    val SHIRO_OBFUSCATED_SERVER_LIST_ROOT_URLS: List<Triple<String, Int, Boolean>> = listOf(
        Triple("https://s3.amazonaws.com/psiphon/web/frh2-29ub-lhe0/osl", 0, false),
        Triple("https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/osl", 0, false),
        Triple("https://s3.amazonaws.com/psiphon/web/yttm-zeis-pjjd/osl", 0, false),
    )

    /** AssetManager path of the Shiro set's embedded server
     *  list (2,434 entries), handed to the core exactly the
     *  way SERVER_ENTRIES_ASSET is when the toggle is on. */
    const val SHIRO_SERVER_ENTRIES_ASSET = "flutter_assets/assets/psiphon/server_list_shiro.dat"

    /** AssetManager path of the Shiro fronting-override
     *  specs (the public shiro-fronting-default.json): only
     *  the IP-literal Akamai dial addresses are mapped into
     *  Ember's preresolved-CIDR machinery; see
     *  PsiphonVpnService.shiroPreresolvedCidrs. */
    const val SHIRO_FRONTING_ASSET = "flutter_assets/assets/psiphon/shiro_fronting_default.json"

    /** The Shiro partner config's two shaping flags, applied
     *  only in Shiro mode: indistinguishable TLS for meek,
     *  and the core's built-in CDN-scan fronting spec. */
    const val SHIRO_USE_INDISTINGUISHABLE_TLS = true
    const val SHIRO_FRONTED_MEEK_CDN_SCAN_USE_BUILT_IN_SPEC = true

    /** The Shiro partner config's tunnel pool size, applied
     *  only in Shiro mode. */
    const val SHIRO_TUNNEL_POOL_SIZE = 1
}
