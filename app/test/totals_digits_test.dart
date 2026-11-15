import 'package:flutter_test/flutter_test.dart';
import 'package:firefox_vpn/ui/ember/ember_format.dart';
import 'package:firefox_vpn/xray/xray_models.dart';

void main() {
  test('per-config traffic totals are one fully-English LTR line', () {
    final p = Profile(
      id: 't1',
      protocol: Protocol.trojan,
      totalDownBytes: 1258291200, // 1.2 GB
      totalUpBytes: 356515840, // 340 MB
    );
    final line = fmtProfileTotals(p);
    // Exact expected line: Latin digits, '.' separator, Latin units.
    // Build 2056 (audit Batch 11): the ↓/↑ glyphs are gone —
    // string contexts render "Down X · Up Y" instead.
    expect(line, 'Down 1.2 GB · Up 340 MB');
    // No Arabic-script characters at all (digits or unit words).
    final arabicScript = RegExp(r'[؀-ۿݐ-ݿ]');
    expect(arabicScript.hasMatch(line), isFalse,
        reason: 'traffic line contains Arabic-script characters: $line');
  });

  test('the user-reported sample values format as 35.8 MB / 3.4 MB', () {
    final p = Profile(
      id: 't2',
      protocol: Protocol.trojan,
      totalDownBytes: 37539021, // 35.8 MB
      totalUpBytes: 3565158, // 3.4 MB
    );
    // Build 2056 (audit Batch 11): the ↓/↑ glyphs are gone —
    // string contexts render "Down X · Up Y" instead.
    expect(fmtProfileTotals(p), 'Down 35.8 MB · Up 3.4 MB');
  });
}
