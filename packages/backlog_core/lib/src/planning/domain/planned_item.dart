import '../../claims/domain/claim.dart';
import '../../items/domain/checklist.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../workflow/domain/workflow.dart';

/// An item together with what follows from the rest of the backlog: whether
/// it is blocked, ready to pick up, claimed, how far its children are.
final class PlannedItem {
  const PlannedItem({
    required this.item,
    required this.category,
    required this.openDependencies,
    required this.missingDependencies,
    required this.childCount,
    required this.openChildCount,
    required this.claim,
    required this.isClaimExpired,
    required this.isReady,
  });

  final Item item;

  /// Null when the status is not defined in the workflow.
  final StatusCategory? category;

  /// Dependencies that exist but are not done yet.
  final List<ItemId> openDependencies;

  /// Dependencies that point to no item at all (also block).
  final List<ItemId> missingDependencies;
  final int childCount;
  final int openChildCount;

  /// Lock on the item, expired or not.
  final Claim? claim;
  final bool isClaimExpired;

  /// Pickable status, nothing blocking, no open children, not claimed.
  final bool isReady;

  ItemId get id => item.id;

  bool get isDone => category == StatusCategory.done;

  bool get isBlocked => !isDone && (openDependencies.isNotEmpty || missingDependencies.isNotEmpty);

  /// Held by an agent right now.
  bool get isClaimed => claim != null && !isClaimExpired;

  Checklist get checklist => item.checklist;
}
