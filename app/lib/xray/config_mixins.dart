/// Config mixins (build 2043).
///
/// The user's own additions to the final core config, applied at the
/// end of every tunnel-config build — the LxBox "Config Mixins"
/// feature (2026-11-13). A mixin is one JSON object the user types
/// in Settings; it survives subscription refreshes and rebuilds
/// because it lives on [XraySettings.configMixins], not on any
/// profile, and it is merged into the config the builder emits
/// (config_builder.dart) rather than into a profile's outbound.
///
/// The mechanism is the app's own: the tunnel config is a Dart map
/// the builder serialises, so merging a user object into it is the
/// same mechanism, not a new engine — no core change is involved.
///
/// Merge rules, applied by [applyConfigMixins]:
/// - both sides maps → merge recursively (a mixin can add one key
///   deep inside `dns` without touching its siblings);
/// - both sides lists → the mixin's items are APPENDED after the
///   base items (so the api-first routing rule, which must stay
///   first, is never displaced by a mixin rule);
/// - anything else → the mixin's value REPLACES the base value
///   (so `{"log": {"loglevel": "info"}}` turns logging up).
///
/// Safety, enforced wherever a mixin is read or written:
/// - invalid JSON is refused at save time (the dialog stays open
///   and names the error) and skipped silently at build time, so a
///   corrupt store can never break a connect — an old store (no
///   key) reads as "no mixins", exactly the old behaviour;
/// - a mixin that is valid JSON but wrong for the core (a
///   duplicate outbound tag, a bad value) fails the connect the
///   same way a bad profile does — the core refuses the config
///   and the existing error path shows it. Mixins are a power
///   tool, not a guardrail: the text is applied as written.
/// - the delay/speed-test config is deliberately NOT mixed in:
///   it is a throwaway shape for measuring one outbound, and a
///   mixin adding an inbound or outbound there could break
///   Test All. Mixins apply to the tunnel config only.

import 'dart:convert';

/// The result of parsing mixin text: either a JSON object to merge
/// ([mixins], null when the text is empty) or an [error] naming why
/// the text cannot be used. Empty or whitespace-only text is not
/// an error — it means "no mixins".
class ParsedMixins {
  const ParsedMixins({this.mixins, this.error});
  final Map<String, dynamic>? mixins;
  final String? error;
}

/// Parses mixin text. The top level must be one JSON object;
/// anything else (an array, a scalar, malformed JSON) is an error
/// naming the problem, never silently half-applied.
ParsedMixins parseConfigMixins(String raw) {
  if (raw.trim().isEmpty) return const ParsedMixins();
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    return ParsedMixins(error: 'Invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    return const ParsedMixins(
      error: 'Top level must be a JSON object: {"key": ...}',
    );
  }
  return ParsedMixins(mixins: decoded);
}

/// Merges [mixins] into [base] by the rules above and returns
/// [base]. Both maps must be JSON-decoded maps (every nested map
/// a `Map<String, dynamic>`) — the builder deep-copies its config
/// through JSON before calling this, so a literal-built map whose
/// nested maps inferred narrower types can never throw here on
/// assignment.
Map<String, dynamic> applyConfigMixins(
  Map<String, dynamic> base,
  Map<String, dynamic> mixins,
) {
  for (final entry in mixins.entries) {
    final key = entry.key;
    final mixinValue = entry.value;
    final baseValue = base[key];
    if (baseValue is Map<String, dynamic> &&
        mixinValue is Map<String, dynamic>) {
      applyConfigMixins(baseValue, mixinValue);
    } else if (baseValue is List && mixinValue is List) {
      baseValue.addAll(mixinValue);
    } else {
      base[key] = mixinValue;
    }
  }
  return base;
}

/// The mixin object for stored text, or null when there is none or
/// the stored text is invalid — the build-time gate: an invalid
/// stored value is skipped, never trusted into a config.
Map<String, dynamic>? mixinsFromStoredText(String raw) =>
    parseConfigMixins(raw).mixins;
