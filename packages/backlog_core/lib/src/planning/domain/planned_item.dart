import '../../claims/domain/claim.dart';
import '../../items/domain/checklist.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../workflow/domain/workflow.dart';
import 'review_state.dart';

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
    this.conflictsWith = const [],
    this.changedFiles = const [],
    this.needsHuman = false,
    this.ancestors = const [],
    this.epics = const [],
    this.review = ReviewState.none,
    this.reviewedHead = false,
    this.at,
  });

  final Item item;

  /// When the snapshot it belongs to was taken: "now" for filters by age;
  /// null outside a snapshot.
  final DateTime? at;

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

  /// Pickable status, nothing blocking, no conflict, no open children, not
  /// claimed.
  final bool isReady;

  /// Active items whose `touches` overlap this open item's: it waits for
  /// them so that two agents do not change the same files. Empty for items
  /// that are not open or have no `touches`.
  final List<ItemId> conflictsWith;

  /// For an active item: the files its branch changed since it forked from
  /// the base branch (`BranchChanges`). They count like `touches` entries
  /// when open items are checked for overlaps. Empty for other items.
  final List<String> changedFiles;

  /// Not done, and an agent asked a question in the discussion that nobody
  /// answered yet ([Discussion.openQuestion]): it waits for a person and is
  /// not ready.
  final bool needsHuman;

  /// Parent, grandparent, … up to the root (cycles cut off).
  final List<ItemId> ancestors;

  /// Epics among the item itself and its [ancestors], nearest first.
  final List<ItemId> epics;

  /// Where the review of its work stands ([ReviewState.of]); never
  /// [ReviewState.running] here, only a dispatcher knows that.
  final ReviewState review;

  /// The latest review looked at the current head of the item's branch,
  /// and that head is known: a new review would see nothing new.
  final bool reviewedHead;

  /// The findings of the latest review when it asks for changes
  /// ([Comment.findings]); 0 otherwise.
  int get reviewFindings => item.discussion.lastReview?.findings ?? 0;

  ItemId get id => item.id;

  bool get isDone => category == StatusCategory.done;

  bool get isBlocked => !isDone && (openDependencies.isNotEmpty || missingDependencies.isNotEmpty);

  /// Waits until overlapping work in progress ([conflictsWith]) is done.
  bool get isConflicting => conflictsWith.isNotEmpty;

  /// Held by an agent right now.
  bool get isClaimed => claim != null && !isClaimExpired;

  Checklist get checklist => item.checklist;
}
