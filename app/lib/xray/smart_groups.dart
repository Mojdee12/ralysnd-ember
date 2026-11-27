/// Smart groups (build 2105): user-defined rules that gather
/// profiles into named groups on the V2Ray list, on top of the
/// existing subscription grouping (a profile keeps its
/// subscription; a smart group is a second, rule-made home the
/// list can show instead). A rule matches on one profile fact:
///
/// - protocol — the profile's protocol is the value (vless, …);
/// - name — the profile's name contains the value;
/// - address — the server address contains the value;
/// - subscription — the owning subscription's name contains
///   the value;
/// - latency — the last measured delay is at most the value
///   (milliseconds; an unmeasured profile never matches).
///
/// The whole feature is gated by XraySettings.smartGroupsEnabled
/// (default OFF): off, the list renders exactly as before and no
/// rule is evaluated. Rules are stored in the settings document;
/// a rule that fails to parse is dropped at read, never trusted
/// into a match.

import 'xray_models.dart';

class SmartGroupRule {
  SmartGroupRule({
    required this.id,
    this.name = '',
    this.field = 'protocol',
    this.value = '',
  });

  String id;
  String name;
  String field;
  String value;

  static const fields = [
    'protocol',
    'name',
    'address',
    'subscription',
    'latency',
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'field': field,
    'value': value,
  };

  static SmartGroupRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final field = raw['field'];
    if (id is! String || id.isEmpty) return null;
    if (field is! String || !fields.contains(field)) return null;
    final name = raw['name'];
    final value = raw['value'];
    return SmartGroupRule(
      id: id,
      name: name is String ? name : '',
      field: field,
      value: value is String ? value : '',
    );
  }

  /// The group's display name: the rule's own name, or a plain
  /// description of the rule when the user left it blank.
  String get label {
    if (name.trim().isNotEmpty) return name.trim();
    return switch (field) {
      'protocol' => 'Protocol: $value',
      'name' => 'Name contains “$value”',
      'address' => 'Server contains “$value”',
      'subscription' => 'Subscription: $value',
      'latency' => 'Latency ≤ ${value} ms',
      _ => value,
    };
  }
}

/// Whether [p] belongs to [rule]'s group. [subscriptionName] is
/// the name of the profile's subscription ('' when it has none).
/// An empty rule value matches nothing — a half-typed rule in the
/// editor must not swallow the whole list.
bool smartGroupMatches(
  SmartGroupRule rule,
  Profile p, {
  String subscriptionName = '',
}) {
  final value = rule.value.trim();
  if (value.isEmpty) return false;
  return switch (rule.field) {
    'protocol' => p.protocol.name.toLowerCase() == value.toLowerCase(),
    // The name the user sees (their rename when there is one),
    // not the provider's original: rules are written against
    // the list on screen.
    'name' => p.displayName.toLowerCase().contains(value.toLowerCase()),
    'address' => p.address.toLowerCase().contains(value.toLowerCase()),
    'subscription' => subscriptionName.toLowerCase().contains(
      value.toLowerCase(),
    ),
    'latency' => _latencyMatches(p, value),
    _ => false,
  };
}

bool _latencyMatches(Profile p, String value) {
  final limit = int.tryParse(value);
  if (limit == null || limit < 0) return false;
  // delayMs < 0 is "never measured" (or a failed test's marker):
  // an unmeasured profile is not a fast profile.
  return p.delayMs >= 0 && p.delayMs <= limit;
}

/// The profiles of [profiles] that belong to [rule]'s group, in
/// list order.
List<Profile> smartGroupMembers(
  SmartGroupRule rule,
  List<Profile> profiles, {
  required String Function(Profile) subscriptionNameOf,
}) {
  return [
    for (final p in profiles)
      if (smartGroupMatches(rule, p, subscriptionName: subscriptionNameOf(p)))
        p,
  ];
}
