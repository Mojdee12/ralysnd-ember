/// Build 2059 gates — grouped Medium/Low sweep part 2 (audit §5/§6
/// appearance groups + §6 engine lows + WG-conf divergence): WG home
/// name overflow, 48 px custom-header close buttons, QR dialog title
/// overflow, one card system (GlassCard renders through MapGlass),
/// one dialog system (theme owns every dialog), editor chrome split,
/// AWG TUN MTU from Settings, AWG v6 route only with a v6 address,
/// and the WARP status-title label recorded from build 2056.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:firefox_vpn/ui/ember/ember_theme.dart';
import 'package:firefox_vpn/ui/ember/map_widgets.dart';

String _read(String path) => File(path).readAsStringSync();

String _dart(String path) => _read('lib/$path');

void main() {
  group('WG home name never overflows (audit §6 appearance low)', () {
    // Build 2075 pin update: the title ternary grew the
    // honest-peer branch (item 18 — "Tunnel up" when the peer
    // has not answered); the invariant this group protects —
    // the line ellipsises, never overflows — is unchanged and
    // still pinned below.
    test('the Connected line ellipsises', () {
      final src = _dart('ui/ember/wireguard_pages.dart');
      expect(
        src,
        contains(
          "? 'Tunnel up: \${selected.displayName}'\n"
          "                              : 'Connected: \${selected.displayName}')\n"
          "                        : 'Not connected',\n"
          "                    style: Ember.heading,\n"
          "                    // Build 2059 (audit §6 appearance low): the name\n"
          "                    // can be long — ellipsis, never overflow.\n"
          "                    overflow: TextOverflow.ellipsis,\n"
          "                    maxLines: 1,",
        ),
      );
    });
  });

  // Build 2074 (UI audit item 4): panel close buttons grew from
  // the 32 px pattern to the 48 dp minimum touch target.
  group('custom-header close buttons are 48 px like MapPanelHeader', () {
    for (final file in [
      'ui/ember/lantern_pages.dart',
      'ui/ember/wireguard_pages.dart',
      'ui/ember/aether_pages.dart',
    ]) {
      test('$file: close button uses the 48 px pattern', () {
        final src = _dart(file);
        expect(
          src,
          contains(
            'icon: const Icon(Icons.close_rounded, size: 19),',
          ),
        );
        // Dart-format splits the constraints across lines; pin
        // the two values, not the line shape.
        expect(src, contains('minWidth: 48,'));
        expect(src, contains('minHeight: 48,'));
        // The old bare 48 px form: `Icons.close_rounded,` at line end.
        expect(src.contains('Icons.close_rounded,\n'), isFalse);
      });
    }
  });

  group('QR dialog title never overflows a long name', () {
    test('the QR dialog title ellipsises', () {
      final src = _dart('ui/ember/qr_pages.dart');
      // Build 2092: the pin's literal indentation drifted when
      // the dialog gained its OverlayGuard wrapper (the title
      // sits one level deeper now). The invariant this pin
      // protects — the title ellipsises at one line — is
      // unchanged in the code.
      expect(
        src,
        contains(
          'title: Text(\n'
          '          title,\n'
          '          style: Ember.heading,\n'
          '          overflow: TextOverflow.ellipsis,\n'
          '          maxLines: 1,\n'
          '        ),',
        ),
      );
    });
  });

  group('one card system (audit §5 shared widgets)', () {
    testWidgets('GlassCard renders through MapGlass', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassCard(
              glow: true,
              onTap: () => tapped = true,
              child: const Text('card'),
            ),
          ),
        ),
      );
      expect(find.byType(MapGlass), findsOneWidget);
      expect(find.text('card'), findsOneWidget);
      await tester.tap(find.byType(GlassCard));
      expect(tapped, isTrue);
    });

    test('GlassCard delegates, it does not paint its own card', () {
      final src = _dart('ui/ember/ember_theme.dart');
      final start = src.indexOf('class GlassCard extends StatelessWidget {');
      final next = src.indexOf('\nclass ', start + 10);
      final build = next < 0 ? src.substring(start) : src.substring(start, next);
      // Build 2074: the delegation call now wraps across lines;
      // the pin's intent is unchanged — GlassCard still renders
      // through MapGlass with its full API forwarded.
      expect(
        build,
        contains(
          'MapGlass(padding: padding, glow: glow, onTap: onTap, child: child)',
        ),
      );
      expect(build, contains('padding: padding,'));
      expect(build, contains('glow: glow,'));
      expect(build, contains('onTap: onTap,'));
      expect(build.contains('boxShadow'), isFalse);
    });
  });

  group('one dialog system (audit §5 shared widgets)', () {
    test('no AlertDialog overrides its background any more', () {
      final dartFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final file in dartFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('AlertDialog(')) continue;
          final window = lines.skip(i).take(4).join('\n');
          expect(
            window.contains('backgroundColor:'),
            isFalse,
            reason: '${file.path}:${i + 1} still overrides the dialog background',
          );
        }
      }
    });

    test('the app theme owns every dialog shape', () {
      final src = _dart('ui/app.dart');
      expect(src, contains('dialogTheme: DialogThemeData('));
      expect(
        src,
        contains(
          'shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),',
        ),
      );
    });
  });

  group('editor chrome is one map surface (audit §6 appearance low)', () {
    test('the body extends behind the transparent app bar', () {
      final src = _dart('ui/ember/profile_editor.dart');
      expect(src, contains('extendBodyBehindAppBar: true,'));
      expect(
        src,
        contains(
          'MediaQuery.of(context).padding.top + kToolbarHeight + 6,',
        ),
      );
    });
  });

  group('AWG uses the Settings MTU (audit §6 WG-conf divergence)', () {
    test('_connectAwg passes settings.tunnelMtu', () {
      final src = _dart('xray/xray_controller.dart');
      expect(src, contains('mtu: settings.tunnelMtu,'));
      expect(src.contains('mtu: p.mtu,'), isFalse);
    });
  });

  group('AWG v6 route only with a v6 address (audit §6 engine low)', () {
    test('the ::/0 route is gated on an assigned v6 address', () {
      // Build 2100 (W-WG2, named reason): startAwgTunnel moved
      // verbatim to AwgVpnService.kt (:awg process); the gating
      // logic is unchanged, only its file moved.
      // Build 2104: the service and its Builder are deleted —
      // the gate now lives in two places, both pinned here:
      // the Dart flag is addresses-only (wg_conf.dart's
      // profileHasIpv6, build 2103 L2), and the Kotlin
      // hand-off adds ::/0 to a route-less peer's AllowedIPs
      // default only under that flag; a peer WITH AllowedIPs
      // routes per its own list in the backend's TUN builder.
      final wgConf = File('lib/xray/wg_conf.dart').readAsStringSync();
      expect(
        wgConf,
        contains("return p.localAddress.split(',').any(v6Of);"),
      );
      final engine = _read(
        'android/app/src/main/kotlin/com/ralysnd/ember/WgTunnelEngine.kt',
      );
      expect(engine, contains('if (ipv6) "::/0" else null'));
      expect(engine, contains('allowedIPs.isNullOrBlank()'));
    });
  });

  group('WARP status title is a label, not a chip (build 2056)', () {
    test('the engine name renders as plain text', () {
      final src = _dart('ui/ember/aether_pages.dart');
      // PIN UPDATED by build 2145 (composition rebuild):
      // the status card's glass is retired; the engine
      // name renders as the tracked label line of the
      // open composition — still a plain Text label, not
      // a chip — with the title-uppercase fallback kept.
      expect(
        src,
        contains('Text(tracked, style: Ember.microLabelOrange)'),
      );
      expect(src, contains(r"'CLOUDFLARE · ${title.toUpperCase()}'"));
    });
  });
}
