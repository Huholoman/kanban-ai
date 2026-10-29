import '../../items/domain/item_id.dart';
import '../../shared/errors.dart';

/// An agent's exclusive, time-limited right to work on an item.
///
/// The lease keeps a crashed agent from blocking an item forever: without a
/// heartbeat the claim expires and another agent may take the item over.
final class Claim {
  Claim({
    required this.itemId,
    required String agent,
    required this.claimedAt,
    required this.heartbeatAt,
    required this.lease,
  }) : agent = validateAgent(agent);

  final ItemId itemId;
  final String agent;
  final DateTime claimedAt;
  final DateTime heartbeatAt;
  final Duration lease;

  DateTime get expiresAt => heartbeatAt.add(lease);

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Claim heartbeat(DateTime now) =>
      Claim(itemId: itemId, agent: agent, claimedAt: claimedAt, heartbeatAt: now, lease: lease);

  /// Same holder and same moment of claiming: the identity of one claim.
  bool sameAs(Claim other) =>
      other.itemId == itemId && other.agent == agent && other.claimedAt.isAtSameMomentAs(claimedAt);

  static String validateAgent(String agent) {
    final trimmed = agent.trim();
    if (trimmed.isEmpty || trimmed.contains('\n')) {
      throw InvalidInputException('Invalid agent name "$agent".');
    }
    return trimmed;
  }
}

/// Port for claim storage. Both acquiring operations must be atomic: when
/// several agents race for one item, exactly one of them may win.
abstract interface class ClaimStore {
  Future<List<Claim>> all();

  Future<Claim?> find(ItemId id);

  /// Records [claim] unless the item already has one; false if it has.
  Future<bool> tryAcquire(Claim claim);

  /// Replaces the [expired] claim with [replacement]; false when the stored
  /// claim is no longer [expired] (someone else was faster).
  Future<bool> tryReplace(Claim expired, Claim replacement);

  /// Overwrites the holder's own claim, e.g. after a heartbeat.
  Future<void> refresh(Claim claim);

  Future<void> remove(ItemId id);
}
