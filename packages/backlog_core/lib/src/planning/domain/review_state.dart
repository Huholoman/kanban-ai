import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';

/// Where the review of an item's work stands, from its latest review
/// comment ([Discussion.lastReview]) compared with its branch and, in a
/// running dispatcher, the review actions running for it.
enum ReviewState {
  /// No review comment yet.
  none,

  /// A review action runs (or waits to run) for the item; only a
  /// dispatcher knows (see `DispatchPlan.reviewOf`).
  running,

  /// The latest review found nothing to change, and the branch has no
  /// newer commits.
  ok,

  /// The latest review asks for changes, and the branch has no newer
  /// commits.
  changes,

  /// The item's branch has commits the latest review did not see.
  stale;

  /// [ReviewState] by name; [none] for anything unknown.
  static ReviewState parse(String? value) => values.firstWhere((v) => v.name == value, orElse: () => none);

  /// The state of [item] whose branch has [head] now (null: unknown).
  static ReviewState of(Item item, BranchHead? head) {
    final review = item.discussion.lastReview;
    if (review == null) return none;
    if (head != null && head.isNewerThan(review)) return stale;
    return review.review == ReviewVerdict.ok ? ok : changes;
  }
}

/// The commit a branch points to.
final class BranchHead {
  const BranchHead({required this.commit, required this.committedAt});

  /// Full commit id, lower case.
  final String commit;

  /// Its committer date.
  final DateTime committedAt;

  /// Whether this head has commits the [review] did not see: it names
  /// another commit, or (when the review names none) the head was committed
  /// after the review was written.
  bool isNewerThan(Comment review) => switch (review.commit) {
    final reviewed? => !commit.startsWith(reviewed),
    null => committedAt.isAfter(review.at),
  };
}

/// Port: the heads of the branches of the code repository (branch name →
/// head), for telling outdated reviews ([ReviewState.stale]). Empty when
/// there is no repository to ask.
abstract interface class BranchHeads {
  Future<Map<String, BranchHead>> heads();
}
