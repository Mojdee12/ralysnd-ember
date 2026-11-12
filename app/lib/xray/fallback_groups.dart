/// Fallback groups (build 2035, Iran-priority queue item 2a).
///
/// A group is the set of profiles that came from one subscription;
/// hand-added profiles (no subscription) form one group of their
/// own. The servers page already groups by subscription, so the
/// fallback group is the group the user already sees — no separate
/// group management to learn, and a subscription refresh keeps the
/// group in sync for free (new profiles join, deleted ones leave).
///
/// The rule, Hiddify's semantics: when a config dies or fails to
/// connect, try the group's members in order and skip one that
/// failed for a while. Tested members go first (fastest first),
/// untested members are last-resort candidates (they may work —
/// the old adaptive failover never tried them at all), and once
/// the group is exhausted the rest of the list is tried in the
/// same order. This file is pure (no platform, no I/O) so the
/// ordering is unit-testable without a device or a core.

import 'xray_models.dart';

/// A member that failed is skipped for this long: long enough to
/// stop the flapping the old failover could do (straight back onto
/// the config that just died), short enough that a member that
/// recovers rejoins the group on its own.
const fallbackCooldown = Duration(minutes: 10);

/// The group a profile belongs to: its subscription id ('' = the
/// hand-added group).
String fallbackGroupKey(Profile p) => p.subscriptionId;

/// The members of [current]'s group, in display order: tested
/// members first by delay (fastest first), then untested members
/// in list order. Includes [current] itself and members the core
/// cannot run (the card shows them as unavailable, not hidden).
List<Profile> fallbackGroupMembersOf(List<Profile> all, Profile current) {
  final members = all
      .where((p) => p.subscriptionId == current.subscriptionId)
      .toList();
  members.sort(_memberOrder);
  return members;
}

/// Ordered failover candidates for [current]: its group first,
/// then every other profile, each section tested-by-delay first
/// and untested last. Excludes [current] itself, profiles the
/// core cannot run (TUIC/AnyTLS — they refuse to connect by
/// design), and members in [coolingDownIds].
List<Profile> fallbackOrder({
  required List<Profile> all,
  required Profile current,
  Set<String> coolingDownIds = const {},
}) {
  bool eligible(Profile p) =>
      p.id != current.id &&
      p.protocol.supportedByCore &&
      !coolingDownIds.contains(p.id);
  final group = all
      .where((p) => p.subscriptionId == current.subscriptionId && eligible(p))
      .toList()
    ..sort(_memberOrder);
  final rest = all
      .where((p) => p.subscriptionId != current.subscriptionId && eligible(p))
      .toList()
    ..sort(_memberOrder);
  return [...group, ...rest];
}

/// Tested members sort by delay; untested members (delayMs < 0)
/// sort after every tested one, in list order (a stable sort
/// keeps their relative order). A member whose last test failed
/// still has delayMs < 0, so it lands here too — it is a
/// last-resort candidate, not a first pick.
int _memberOrder(Profile a, Profile b) {
  final ad = a.delayMs < 0 ? 1 << 30 : a.delayMs;
  final bd = b.delayMs < 0 ? 1 << 30 : b.delayMs;
  return ad.compareTo(bd);
}
