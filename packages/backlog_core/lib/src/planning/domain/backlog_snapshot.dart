import '../../claims/domain/claim.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_time.dart';
import '../../items/domain/path_glob.dart';
import '../../workflow/domain/workflow.dart';
import 'planned_item.dart';
import 'review_state.dart';

/// The whole backlog at one moment: items, their relations and claims (and
/// the heads of the code repository's branches, for outdated reviews).
///
/// Everything derived (blocked, ready, cycles, …) is computed here, in one
/// place, so that the CLI, a server and the app all agree on it.
final class BacklogSnapshot {
  BacklogSnapshot._(this.workflow, this.takenAt, this._byId, this.items, this._children, this._dependents);

  /// With duplicate ids the first item wins; the linter reports the rest.
  factory BacklogSnapshot.build({
    required Iterable<Item> items,
    required Workflow workflow,
    Iterable<Claim> claims = const [],
    required DateTime now,
    Map<String, BranchHead> branchHeads = const {},
  }) {
    final byId = <ItemId, Item>{};
    for (final item in items) {
      byId.putIfAbsent(item.id, () => item);
    }
    final claimsById = {for (final claim in claims) claim.itemId: claim};
    final children = <ItemId, List<ItemId>>{};
    final dependents = <ItemId, List<ItemId>>{};
    for (final item in byId.values) {
      if (item.parent != null) (children[item.parent!] ??= []).add(item.id);
      for (final dependency in item.dependsOn) {
        (dependents[dependency] ??= []).add(item.id);
      }
    }

    bool isDone(ItemId id) => workflow.categoryOf(byId[id]!.status) == StatusCategory.done;

    List<ItemId> ancestorsOf(Item item) {
      final chain = <ItemId>[];
      for (var parent = item.parent; parent != null && parent != item.id && !chain.contains(parent);) {
        chain.add(parent);
        parent = byId[parent]?.parent;
      }
      return chain;
    }

    // Work in progress and the files it touches; open items overlapping it wait.
    final globs = {
      for (final item in byId.values)
        if (item.touches.isNotEmpty) item.id: [for (final pattern in item.touches) PathGlob(pattern)],
    };
    final active = [
      for (final id in globs.keys)
        if (workflow.categoryOf(byId[id]!.status) == StatusCategory.active) id,
    ]..sort();
    List<ItemId> conflictsOf(Item item) => workflow.categoryOf(item.status) != StatusCategory.open
        ? const []
        : [
            for (final other in active)
              if (PathGlob.anyOverlap(globs[item.id] ?? const [], globs[other]!)) other,
          ];

    final planned = <ItemId, PlannedItem>{};
    for (final item in byId.values) {
      final category = workflow.categoryOf(item.status);
      final open = item.dependsOn.where((d) => byId.containsKey(d) && !isDone(d)).toList();
      final missing = item.dependsOn.where((d) => !byId.containsKey(d)).toList();
      final kids = children[item.id] ?? const [];
      final openKids = kids.where((k) => !isDone(k)).length;
      final claim = claimsById[item.id];
      final expired = claim != null && claim.isExpiredAt(now);
      final blocked = category != StatusCategory.done && (open.isNotEmpty || missing.isNotEmpty);
      final pickable = workflow.status(item.status)?.pickable ?? false;
      final ancestors = ancestorsOf(item);
      final conflicts = conflictsOf(item);
      final needsHuman = category != StatusCategory.done && item.discussion.openQuestion != null;
      final branch = item.branch?.trim();
      final head = branchHeads[branch == null || branch.isEmpty ? 'agent/${item.id}' : branch];
      final review = ReviewState.of(item, head);
      planned[item.id] = PlannedItem(
        item: item,
        category: category,
        openDependencies: open,
        missingDependencies: missing,
        childCount: kids.length,
        openChildCount: openKids,
        claim: claim,
        isClaimExpired: expired,
        isReady:
            pickable && !blocked && conflicts.isEmpty && !needsHuman && openKids == 0 && (claim == null || expired),
        conflictsWith: conflicts,
        needsHuman: needsHuman,
        ancestors: ancestors,
        epics: [
          for (final id in [item.id, ...ancestors])
            if (byId[id]?.type == 'epic') id,
        ],
        review: review,
        reviewedHead: head != null && (review == ReviewState.ok || review == ReviewState.changes),
        at: now,
      );
    }

    final ordered = planned.values.toList()..sort((a, b) => compareDefault(workflow, a, b));
    return BacklogSnapshot._(workflow, now, planned, List.unmodifiable(ordered), children, dependents);
  }

  final Workflow workflow;
  final DateTime takenAt;
  final Map<ItemId, PlannedItem> _byId;
  final Map<ItemId, List<ItemId>> _children;
  final Map<ItemId, List<ItemId>> _dependents;

  /// In default order: priority, then age, then id.
  final List<PlannedItem> items;

  Iterable<ItemId> get ids => _byId.keys;

  PlannedItem? operator [](ItemId id) => _byId[id];

  /// Ready items, most urgent first ([compareReady]).
  List<PlannedItem> get ready => items.where((i) => i.isReady).toList()..sort((a, b) => compareReady(workflow, a, b));

  List<PlannedItem> get blocked => items.where((i) => i.isBlocked).toList();

  /// Unfinished items with a question for a person.
  List<PlannedItem> get needingHuman => items.where((i) => i.needsHuman).toList();

  /// Open items waiting for overlapping work in progress.
  List<PlannedItem> get conflicting => items.where((i) => i.isConflicting).toList();

  /// Open items that wait for the active item [id] because their `touches`
  /// overlap.
  List<PlannedItem> waitingOn(ItemId id) => items.where((i) => i.conflictsWith.contains(id)).toList();

  List<PlannedItem> childrenOf(ItemId id) => _resolve(_children[id]);

  /// Items that wait for [id].
  List<PlannedItem> dependentsOf(ItemId id) => _resolve(_dependents[id]);

  List<List<ItemId>> dependencyCycles() => _cycles((item) => item.dependsOn);

  List<List<ItemId>> parentCycles() => _cycles((item) => [?item.parent]);

  List<PlannedItem> _resolve(List<ItemId>? ids) =>
      (ids ?? const <ItemId>[]).map((id) => _byId[id]!).toList()..sort((a, b) => compareDefault(workflow, a, b));

  List<List<ItemId>> _cycles(Iterable<ItemId> Function(Item item) edges) {
    const visiting = 1, finished = 2;
    final state = <ItemId, int>{};
    final path = <ItemId>[];
    final found = <String, List<ItemId>>{};

    void visit(ItemId id) {
      state[id] = visiting;
      path.add(id);
      for (final next in edges(_byId[id]!.item)) {
        if (!_byId.containsKey(next)) continue;
        if (state[next] == visiting) {
          final cycle = path.sublist(path.indexOf(next));
          found.putIfAbsent((cycle.map((i) => i.value).toList()..sort()).join(','), () => cycle);
        } else if (state[next] == null) {
          visit(next);
        }
      }
      path.removeLast();
      state[id] = finished;
    }

    for (final id in _byId.keys) {
      if (state[id] == null) visit(id);
    }
    return found.values.toList();
  }

  /// The order of ready work: milestone first (as listed in the workflow;
  /// none, `later` and unknown ones last), then [compareDefault].
  static int compareReady(Workflow workflow, PlannedItem a, PlannedItem b) {
    final byMilestone = workflow.milestoneRank(a.item.milestone).compareTo(workflow.milestoneRank(b.item.milestone));
    return byMilestone != 0 ? byMilestone : compareDefault(workflow, a, b);
  }

  static int compareDefault(Workflow workflow, PlannedItem a, PlannedItem b) {
    final byPriority = workflow.priorityRank(a.item.priority).compareTo(workflow.priorityRank(b.item.priority));
    if (byPriority != 0) return byPriority;
    final byCreated = ItemTime.compare(a.item.created, b.item.created);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }
}
