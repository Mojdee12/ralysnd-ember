package com.ralysnd.ember

/**
 * The Psiphon engine's bootstrap identity: the propagation channel,
 * sponsor and server-list trust anchors the tunnel core needs before
 * it can find any server.
 *
 * Provenance (2026-10-31): Psiphon's public repos ship only stubs for
 * these values (EmbeddedValues.java.stub is empty; the sample config
 * is a "..." placeholder) because production values are injected at
 * Psiphon's private build time. These constants were therefore taken
 * from the official Psiphon Android app as published by Psiphon Inc.
 * (com.psiphon3, versionName 2.5.13, versionCode 509, downloaded from
 * https://psiphon.ca/PsiphonAndroid.apk): its res/raw/psiphon_config
 * resource carries exactly this set, and res/raw/
 * psiphon_embedded_servers carries the 400 embedded server entries
 * bundled here as assets/psiphon/embedded_servers.txt.
 * (Build 2069: the official config's AdditionalParameters blob is
 * deliberately NOT carried here any more — it overrides the
 * server-list URLs with a different channel's; see buildConfig.)
 *
 * Note: Psiphon's current terms allow the network to be used through
 * official clients (partnership-only embedding). This integration
 * exists at the app owner's explicit instruction, with that
 * restriction known and accepted.
 */
object PsiphonConstants {
    const val SOCKS_PORT = 11808
    const val HTTP_PORT = 11809

    const val CLIENT_VERSION = "509"
    const val PROPAGATION_CHANNEL_ID = "92AACC5BABE0944C"
    const val SPONSOR_ID = "40001BC527D3D099"
    const val REMOTE_SERVER_LIST_SIGNATURE_PUBLIC_KEY = "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="
    const val SERVER_ENTRY_SIGNATURE_PUBLIC_KEY = "sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA="

    /** AssetManager path (Flutter asset) of the embedded server list. */
    const val EMBEDDED_SERVERS_ASSET = "flutter_assets/assets/psiphon/embedded_servers.txt"

    // ---- Build 2065: server-list freshness, anti-hijack DNS, ladder ----
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

    /** Obfuscation key for the obfuscated server list (official). */
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
     * Anti-DNS-hijack resolvers (ralysnd's PSIPHON_ALTERNATE_DNS):
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
     *  (ralysnd PsiphonCleanIps provider table). */
    const val FRONTING_PROVIDER_AKAMAI = "BACEC04E64813F2B"
    const val FRONTING_PROVIDER_FASTLY = "089D05B86ACE8D3B"

    /** The FRONTED protocol family (ralysnd PsiphonMethods.FRONTED). */
    val FRONTED_PROTOCOLS: List<String> = listOf(
        "FRONTED-MEEK-OSSH",
        "FRONTED-MEEK-HTTP-OSSH",
        "FRONTED-MEEK-QUIC-OSSH",
    )

    // Build 2069: the fork core's FRONTED-MEEK-CDN-* protocol
    // names are GONE from this file. They do not exist in the
    // transplanted stock v2.0.39 binary (0 occurrences), and
    // the ladder no longer names them — see rung A in
    // PsiphonVpnService.buildConfig.

    /** TCP-only protocols that can ride an upstream proxy
     *  (ralysnd PsiphonMethods.PROTOCOLS_CHAINABLE). */
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
}
