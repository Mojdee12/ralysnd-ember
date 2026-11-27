/// Build 2095 (feature 7 — session data budget): the pure
/// verdict the shell's budget tick acts on. Off (cap 0)
/// never fires; warn at 80% of the cap; exceeded at it.
enum BudgetVerdict { ok, warn, exceeded }

BudgetVerdict sessionBudgetVerdict({
  required int usedBytes,
  required int capMb,
}) {
  if (capMb <= 0) return BudgetVerdict.ok;
  final capBytes = capMb * 1024 * 1024;
  if (usedBytes >= capBytes) return BudgetVerdict.exceeded;
  if (usedBytes * 5 >= capBytes * 4) return BudgetVerdict.warn;
  return BudgetVerdict.ok;
}
