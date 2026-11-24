// Build 2074 — the MASQUE rungs 5–6 port (full-review
// §9 item 7 / §4 row 16 / §1.6; progress-file scope note from
// build 2052).
//
// Ember's Aether stack shipped rungs 1–4 only (ECH ×3 + plain).
// This build ports ralysnd's two missing registration rungs
// into AetherCore.kt, from the on-disk ralysnd 1.2.45 source
// (~/workspace/new-panel/handover/Ralysnd-Handover/):
//   - rung 5 "semipy": the semi-python ClientHello (AetherTls
//     env table) with the fragment;
//   - rung 6 "tlshello": the same ClientHello dialled out
//     through a local Xray exit (AetherXrayExit) whose freedom
//     outbound cuts the hello into TLS records with the
//     tlshello-0-len finalmask.
// Plus the supporting pieces the review names: the rung winner
// remembered PER NETWORK (AetherRegisterMemory, hashed key,
// never an SSID) and MasqueCarrier h3/h2 learning for the
// "auto" transport (new chip on the MASQUE page).
//
// The bundled libaether.so IS Aether 2.4.0 (verified in its
// strings: "aether 2.4.0" plus every AETHER_TLS_* /
// AETHER_UPSTREAM / AETHER_MASQUE_H2_FRAGMENT name the port
// uses), so the env vars are live. The exit config's exact
// bytes were accepted by the host core binary under
// `run -test` ("Configuration OK.") and the exit's SOCKS port
// answered a real greeting in the gate run — see BUILD-LOG-2.
//
// These pins prove the wiring. What only the owner's phone can
// prove — a semipy/tlshello identity actually registering on
// a filtered network, and an auto session learning h2 — is
// NOT claimed here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String ktSrc(String rel) =>
    File('android/app/src/main/kotlin/com/ralysnd/ember/$rel')
        .readAsStringSync();

String dartSrc(String rel) => File('lib/$rel').readAsStringSync();

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

void main() {
  group('AetherTls: the semi-python env table', () {
    test('SEMI_PYTHON carries the full ralysnd env table', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('enum class AetherTls');
      expect(at, greaterThan(0), reason: 'AetherTls is ported');
      final table = kt.substring(at, kt.indexOf('companion object', at));
      // All eight env vars, with ralysnd's exact values.
      expect(
        table.contains(
          '"AETHER_TLS_CIPHERS" to "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"',
        ),
        isTrue,
        reason: 'TLS 1.2 suites in Python order',
      );
      expect(
        table.contains(
          'ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256"',
        ),
        isTrue,
        reason: 'the CBC-SHA256 pair closes the 1.2 list',
      );
      expect(
        table.contains(
          '"AETHER_TLS13_CIPHERS" to "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256"',
        ),
        isTrue,
        reason: 'TLS 1.3 order is Python\'s',
      );
      expect(
        table.contains(
          '"AETHER_TLS_GROUPS" to "X25519MLKEM768:X25519:P-256:P-384:P-521"',
        ),
        isTrue,
      );
      expect(
        table.contains(
          '"AETHER_TLS_SIGALGS" to "mldsa65:mldsa87:mldsa44:ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:"',
        ),
        isTrue,
      );
      for (final flag in [
        '"AETHER_DISABLE_GREASE" to "1"',
        '"AETHER_DISABLE_OCSP_STAPLING" to "1"',
        '"AETHER_DISABLE_SCT" to "1"',
        '"AETHER_DISABLE_EXTENSION_PERMUTATION" to "1"',
      ]) {
        expect(table.contains(flag), isTrue, reason: '$flag is set');
      }
      expect(occurrences(table, '"AETHER_'), 8,
          reason: 'exactly the eight env vars, no more, no fewer');
    });

    test('CHROME sets nothing and byKey falls back to it', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('CHROME("chrome", "Chrome", emptyMap())'), isTrue,
          reason: 'the core\'s own ClientHello sets no env');
      expect(
        kt.contains(
          'fun byKey(key: String?): AetherTls = values().firstOrNull { it.key == key } ?: CHROME',
        ),
        isTrue,
        reason: 'an unknown stored key resolves to CHROME, never crashes',
      );
    });
  });

  group('rung ladder: six rungs, same budgets', () {
    test('the ladder is ech-udp, ech-doh, ech-tcp, plain, semipy, tlshello', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('private val rungs = listOf(');
      expect(at, greaterThan(0), reason: 'the rung list exists');
      final ladder = kt.substring(at, kt.indexOf(')', kt.indexOf('Rung("tlshello"', at)) + 1);
      final order = [
        'Rung("ech-udp", "udp://1.1.1.1")',
        'Rung("ech-doh", "https://1.1.1.1/dns-query")',
        'Rung("ech-tcp", "tcp://8.8.8.8")',
        'Rung("plain", null)',
        'Rung("semipy", null, tls = AetherTls.SEMI_PYTHON, fragment = true)',
        'Rung("tlshello", null, tls = AetherTls.SEMI_PYTHON, tlsHello = true)',
      ];
      var pos = -1;
      for (final rung in order) {
        final found = ladder.indexOf(rung);
        expect(found, greaterThan(pos),
            reason: '$rung is present and after the previous rung');
        pos = found;
      }
      expect(occurrences(ladder, 'Rung('), 6,
          reason: 'exactly six rungs — the first four unchanged, two added');
      // The Rung model carries the new fields with safe defaults.
      expect(
        kt.contains(
          'private data class Rung(\n        val key: String,\n        val dns: String?,\n        val tls: AetherTls = AetherTls.CHROME,\n        val fragment: Boolean = false,\n        val tlsHello: Boolean = false,\n    )',
        ),
        isTrue,
        reason: 'old rungs keep their CHROME / no-fragment / no-exit shape',
      );
    });

    test('35 s per rung and 180 s total are unchanged', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('SystemClock.elapsedRealtime() - started > 180_000'), isTrue,
          reason: 'the total budget still binds all six rungs');
      expect(kt.contains('val deadline = SystemClock.elapsedRealtime() + 35_000'), isTrue,
          reason: 'the per-rung budget is still 35 s');
      expect(kt.contains('180 s total for all six rungs'), isTrue,
          reason: 'the budget comment says the total did not change');
    });

    test('the remembered rung still runs first, unknown keys cannot crash', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains(
          'val ordered = (listOfNotNull(rungs.firstOrNull { it.key == remembered }) + rungs).distinct()',
        ),
        isTrue,
        reason: 'remembered-first ordering is unchanged; an unknown stored key yields null and the ladder runs in listed order',
      );
    });
  });

  group('per-network rung memory', () {
    test('RegisterMemory is per network + slot, hashed, never an SSID', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('object AetherRegisterMemory');
      expect(at, greaterThan(0), reason: 'RegisterMemory is ported');
      final mem = kt.substring(at, kt.indexOf('object MasqueCarrier', at));
      expect(mem.contains('private const val PREFS = "aether_register"'), isTrue,
          reason: 'its own prefs file, not the per-slot one');
      expect(
        mem.contains('private fun slotKey(network: String, slotId: String) = "\$network|\$slotId"'),
        isTrue,
        reason: 'the key is network + slot — the two slots keep separate winners',
      );
      final keyAt = kt.indexOf('object AetherNetworkKey');
      expect(keyAt, greaterThan(0), reason: 'the network key is ported');
      final keyFn = kt.substring(keyAt, kt.indexOf('object AetherRegisterMemory', keyAt));
      expect(keyFn.contains('MessageDigest.getInstance("SHA-256")'), isTrue,
          reason: 'the raw key is hashed before it is kept');
      expect(keyFn.contains('"%02x".format(it.toInt() and 0xff)'), isTrue,
          reason: 'hex is canonical — a negative byte never prints ffffff',
      );
      expect(keyFn.contains('wifi.connectionInfo') || keyFn.contains('connectionInfo.networkId'), isTrue,
          reason: 'Wi-Fi identity is the saved-network id, not the SSID');
      expect(keyFn.contains('networkOperatorName'), isTrue,
          reason: 'mobile identity is the carrier operator name');
    });

    test('ensureIdentity reads the legacy per-slot pref as a fallback', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains(
          'val remembered = AetherRegisterMemory.get(context, network, id)\n            ?: prefs.getString("rung-\$id", null)',
        ),
        isTrue,
        reason: 'a winner stored by builds 2032–2073 still resolves',
      );
      expect(
        kt.contains('AetherRegisterMemory.remember(context, network, id, rung.key)'),
        isTrue,
        reason: 'a new winner is remembered per network',
      );
      expect(
        kt.contains('AetherRegisterMemory.forget(context, network, id)'),
        isTrue,
        reason: 'a failed remembered rung forgets the network memory too',
      );
    });
  });

  group('AetherXrayExit: the tlshello rung', () {
    test('the exit config is ralysnd\'s shape, byte for byte', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('fun config(port: Int): String');
      expect(at, greaterThan(0), reason: 'the exit config exists');
      final cfg = kt.substring(at, kt.indexOf('""".trimIndent()', at));
      expect(cfg.contains('"listen": "127.0.0.1"'), isTrue,
          reason: 'loopback only');
      expect(cfg.contains('"port": \$port'), isTrue,
          reason: 'the chosen port is substituted');
      expect(cfg.contains('"protocol": "socks"'), isTrue,
          reason: 'SOCKS inbound');
      expect(cfg.contains('"auth": "noauth", "udp": true'), isTrue);
      expect(cfg.contains('"tag": "exit-node"'), isTrue);
      expect(cfg.contains('"protocol": "freedom"'), isTrue,
          reason: 'freedom outbound');
      expect(cfg.contains('"packets": "tlshello"'), isTrue);
      expect(cfg.contains('"lengths": ["0", "104", "1"]'), isTrue,
          reason: 'tlshello-0-len: empty first record, 104 bytes, then the rest');
      expect(cfg.contains('"delays": ["0"]'), isTrue);
      expect(cfg.contains('"maxSplit": "0"'), isTrue);
      expect(cfg.contains('"packets": "1-1"'), isTrue);
      expect(cfg.contains('"lengths": ["114", "1"]'), isTrue);
      expect(cfg.contains('"delays": ["1"]'), isTrue);
      expect(cfg.contains('"maxSplit": "11"'), isTrue);
    });

    test('upstream() names the exit the way Aether expects', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('fun upstream(port: Int) = "socks5://127.0.0.1:\$port"'), isTrue,
          reason: 'AETHER_UPSTREAM is socks5://127.0.0.1:<port>');
    });

    test('the exit is a throwaway libxray subprocess, killed with the shared kill', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('object AetherXrayExit');
      expect(at, greaterThan(0), reason: 'AetherXrayExit is ported');
      final exit = kt.substring(at, kt.indexOf('/** Options for one run', at));
      expect(exit.contains('"libxray.so"'), isTrue,
          reason: 'the bundled core binary, not a ralysnd-only service');
      expect(exit.contains('"run", "-c", configFile.absolutePath'), isTrue,
          reason: 'a config-file run, like XrayTester\'s throwaway instances');
      expect(exit.contains('AtomicFile.writeText(configFile, config(p))'), isTrue,
          reason: 'the config is written atomically, like every other store');
      expect(exit.contains('waitForPort(proc, p, 12_000)'), isTrue,
          reason: 'the exit must answer its SOCKS port before the rung uses it');
      expect(exit.contains('ProcessKill.kill(proc)'), isTrue,
          reason: 'the shared kill (2054 F-M1), so the port is free before any respawn');
      expect(
        exit.contains('if (p == 0 || proc == null || (onlyPort != 0 && onlyPort != p)) return'),
        isTrue,
        reason: 'a late stop cannot end the exit a newer run started',
      );
    });

    test('the tlshello rung never falls back to a direct dial', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains('val port = AetherXrayExit.start(context) ?: return false'),
        isTrue,
        reason: 'a failed exit start fails the rung — it is never a plain run in disguise',
      );
      expect(
        kt.contains('AetherXrayExit.stop(context, port)'),
        isTrue,
        reason: 'the exit is stopped after the run, in a finally',
      );
      expect(kt.contains('if (upstream != null) env["AETHER_UPSTREAM"] = upstream'), isTrue);
      expect(kt.contains('env.putAll(rung.tls.env)'), isTrue,
          reason: 'the rung\'s ClientHello rides the register run');
      expect(kt.contains('if (rung.fragment) env["AETHER_MASQUE_H2_FRAGMENT"] = "1"'), isTrue);
    });
  });

  group('MasqueCarrier: per-network rung memory', () {
    test('the carrier memory is per network and stores ladder rungs', () {
      final kt = ktSrc('AetherCore.kt');
      final at = kt.indexOf('object MasqueCarrier');
      expect(at, greaterThan(0), reason: 'MasqueCarrier is ported');
      final carrier = kt.substring(at, kt.indexOf('/**\n * Which address family', at));
      expect(carrier.contains('private const val PREFS = "masque_carrier"'), isTrue);
      // Build 2083: the 2074 "Accepted ... via HTTP/2" line
      // learner is superseded -- the ladder remembers a rung
      // only after it carried real data (connectMasque), so
      // the memory now stores MasqueRung keys; a stored 2074
      // "h3"/"h2" IS a rung key and resolves unchanged.
      expect(carrier.contains('fun rememberedRung(context: Context): MasqueRung?'), isTrue,
          reason: 'the memory reads as a ladder rung');
      expect(carrier.contains('fun remember(context: Context, rung: MasqueRung)'), isTrue);
      expect(carrier.contains('fun forget(context: Context)'), isTrue);
      expect(carrier.contains('fun onCoreLog'), isFalse,
          reason: 'build 2083: no log-line learning remains in the memory');
      expect(carrier.contains('ACCEPTED'), isFalse,
          reason: 'build 2083: the Accepted-line regex is gone');
    });

    test('auto resolves at start; the ladder owns learning and forgetting', () {
      final kt = ktSrc('AetherCore.kt');
      expect(
        kt.contains('if (ridesMasque && options.transport == MasqueCarrier.AUTO)'),
        isTrue,
        reason: 'only masque/gool sessions resolve auto; wg never touches the carrier',
      );
      // Build 2083: a direct start on auto runs the remembered
      // rung whole (fragment/TLS/exit included), not a bare
      // transport string -- the 2074 startOn resolution is gone.
      expect(
        kt.contains('(MasqueCarrier.rememberedRung(context) ?: MasqueRung.H3)'),
        isTrue,
        reason: 'an auto start runs the remembered rung, else HTTP/3',
      );
      expect(kt.contains('MasqueCarrier.startOn'), isFalse,
          reason: 'build 2083: startOn is superseded by the rung memory');
      expect(kt.contains('onCoreLog'), isFalse,
          reason: 'build 2083: no log line teaches the memory any more');
      expect(kt.contains('autoStartedCarrier'), isFalse,
          reason: 'build 2083: the ladder forgets a failed remembered rung itself');
      expect(kt.contains('if (next == AetherStage.CONNECTED) reachedConnected = true'), isTrue,
          reason: 'a connected session keeps what it learned',
      );
    });
  });


  group('Dart: the Auto transport chip', () {
    test('the MASQUE page offers Auto alongside HTTP/3 and HTTP/2', () {
      final page = dartSrc('ui/ember/aether_pages.dart');
      expect(page.contains("values: const ['h3', 'h2', 'auto']"), isTrue,
          reason: 'auto joins the existing chip row — no new page, no new control family',
      );
      expect(page.contains("'auto' => 'Auto'"), isTrue);
      expect(
        page.contains('Remembers the carrier that worked on this '),
        isTrue,
        reason: 'the auto choice explains itself in the page\'s own caption style',
      );
    });

    test('AetherOptions documents auto; auto is the default (build 2083)', () {
      final platform = dartSrc('aether/aether_platform.dart');
      expect(platform.contains("/// h3 | h2 | auto — the MASQUE carrier transport"), isTrue);
      // Build 2083 supersedes the 2074 pin below it in history:
      // the default is 'auto' (the carrier ladder), and a
      // stored unmarked 'h3' migrates to it
      // (migrateMasqueTransport) — an explicit pick is marked
      // and honored instead.
      expect(platform.contains("this.transport = 'auto'"), isTrue,
          reason: 'build 2083: the ladder is the default route to MASQUE',
      );
      expect(platform.contains("this.transport = 'h3'"), isFalse,
          reason: 'build 2083: h3 is a rung of the ladder, not the default',
      );
    });
  });

  group('header: the non-port is gone', () {
    test('AetherCore.kt no longer states rungs 5–6 are unported', () {
      final kt = ktSrc('AetherCore.kt');
      expect(kt.contains('are NOT\n * ported in this round'), isFalse,
          reason: 'the 2032 non-port note is replaced by the port record',
      );
      expect(kt.contains('ports the two remaining'), isTrue);
      expect(kt.contains('tlshello (Xray-exit)'), isTrue);
    });
  });
}
