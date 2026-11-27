/// Build 2129 (Leg 3): the Senpai scanner's anti-DPI
/// defaults, taken verbatim from the LML bridge
/// (ScannerBridge): the finalmask JSON and the cipher-suite
/// list the bridge substitutes when the UI leaves those
/// fields empty. Kept in their own file because both are
/// long opaque strings — senpai.dart references them by
/// name.
library;

/// LML's default finalmask (Xray finalmask fragment spec).
const senpaiDefaultFinalmask =
    "{\"tcp\":[{\"type\":\"fragment\",\"settings\":{\"packets\":\"tlshello\",\"lengths\":[\"0\",\"104\",\"1\"],\"delays\":[\"0\"],\"maxSplit\":\"0\"}},{\"type\":\"fragment\",\"settings\":{\"packets\":\"1-1\",\"lengths\":[\"114\",\"1\"],\"delays\":[\"1\"],\"maxSplit\":\"11\"}}]}";

/// LML's default TLS cipher-suite list for the anti-DPI
/// probes.
const senpaiDefaultCipherSuites =
    "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256:TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256";
