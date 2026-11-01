import 'package:collection/collection.dart';

import '../../items/domain/item_id.dart';
import '../../workflow/domain/workflow.dart';
import 'backlog_snapshot.dart';
import 'planned_item.dart';

/// Whether an epic can be implemented by one agent on one branch.
enum EpicVerdict {
  /// Nothing stands in the way.
  ok,

  /// It can start, but some items wait for something outside the epic (a
  /// dependency, a person, overlapping work); the agent stops there and asks.
  warning,

  /// It cannot start ([EpicPlan.problems] say why).
  forbidden,
}

/// Where an item of an epic stands in its implementation.
enum EpicMemberState {
  /// In a done status.
  done('done'),

  /// Handed over: in an active status after the first one (e.g. `review`).
  /// Within the epic it counts as finished: its work is on the epic's branch.
  handedOver('handed-over'),

  /// In the first active status (`in-progress`).
  inProgress('in-progress'),

  /// Not started yet.
  remaining('to-do');

  const EpicMemberState(this.id);

  final String id;

  /// Its work is on the branch: later items of the epic may build on it.
  bool get settled => this == done || this == handedOver;
}

/// An item under the epic (at any depth) and what it waits for.
final class EpicMember {
  const EpicMember({
    required this.item,
    required this.state,
    this.after = const [],
    this.waits = const [],
    this.inScope = true,
  });

  final PlannedItem item;
  final EpicMemberState state;

  /// Items of the epic that are not settled yet and come first: its
  /// dependencies and its open children.
  final List<ItemId> after;

  /// What outside the epic keeps it from starting (`X-7f3a (todo)`, `a
  /// person's answer to its question`, …).
  final List<String> waits;

  /// It belongs to the run's milestone ([EpicPlan.milestone]); always true
  /// without one.
  final bool inScope;

  ItemId get id => item.id;

  /// The agent can take it now.
  bool get canStart => inScope && state == EpicMemberState.remaining && after.isEmpty && waits.isEmpty;
}

/// How far the items of an epic in one milestone are ([EpicPlan.progress]).
final class EpicMilestoneProgress {
  const EpicMilestoneProgress({required this.milestone, required this.settled, required this.total});

  /// Null for the items without a milestone.
  final String? milestone;

  /// Handed over or done.
  final int settled;
  final int total;

  bool get finished => settled == total;
}

/// The implementation of an epic (or any item with children) by one agent
/// on one branch: the items under it in the order they can be done, what
/// each waits for, and whether the whole can start ([verdict]).
///
/// Items of the epic that are handed over (e.g. `review`) count as finished
/// for the items after them: their work is already on the epic's branch.
/// Dependencies outside the epic must be done; one that is not done but
/// planned (pickable or active) is a warning, one that is not even planned
/// (or missing) forbids the start, as do dependency cycles among its items.
/// Items waiting for a person or for overlapping work outside the epic are
/// warnings.
///
/// With a [milestone] the run implements only the items of that milestone
/// and those without one ([EpicMember.inScope]); the others stay as they are
/// ([skipped]). An item in the scope that comes after an unsettled item
/// outside it (a dependency or a child) forbids the start: the agent would
/// get stuck there.
final class EpicPlan {
  const EpicPlan._({
    required this.epic,
    required this.branch,
    required this.members,
    required this.problems,
    required this.warnings,
    required this.progress,
    this.agent,
    this.milestone,
  });

  /// The plan of [id] in [snapshot]; [agent] is the one implementing it
  /// (its claims do not count as someone else's); [milestone] limits the
  /// run to the items of that milestone (and those without one).
  factory EpicPlan.of(BacklogSnapshot snapshot, ItemId id, {String? agent, String? milestone}) {
    milestone = milestone?.trim();
    if (milestone != null && milestone.isEmpty) milestone = null;
    final epic = snapshot[id]!;
    final workflow = snapshot.workflow;

    final descendants = <ItemId>{};
    void collect(ItemId parent) {
      for (final child in snapshot.childrenOf(parent)) {
        if (child.id != id && descendants.add(child.id)) collect(child.id);
      }
    }

    collect(id);
    final byDefault = [
      for (final planned in snapshot.items)
        if (descendants.contains(planned.id)) planned,
    ];

    EpicMemberState stateOf(PlannedItem planned) => switch (planned.category) {
      StatusCategory.done => EpicMemberState.done,
      StatusCategory.active when planned.item.status == workflow.activeStatus => EpicMemberState.inProgress,
      StatusCategory.active => EpicMemberState.handedOver,
      _ => EpicMemberState.remaining,
    };
    final states = {for (final planned in byDefault) planned.id: stateOf(planned)};
    bool inScope(ItemId member) {
      if (milestone == null) return true;
      final own = snapshot[member]!.item.milestone;
      return own == null || own == milestone;
    }

    // Children before their parent, dependencies before their dependents,
    // otherwise most urgent first; a cycle is cut where it is found.
    List<ItemId> before(PlannedItem planned) => [
      for (final dependency in planned.item.dependsOn)
        if (descendants.contains(dependency)) dependency,
      for (final child in snapshot.childrenOf(planned.id))
        if (descendants.contains(child.id)) child.id,
    ];
    final ordered = <PlannedItem>[];
    final placed = <ItemId>{};
    final left = [...byDefault];
    while (left.isNotEmpty) {
      final nextUp = left.firstWhereOrNull((p) => before(p).every(placed.contains)) ?? left.first;
      left.remove(nextUp);
      ordered.add(nextUp);
      placed.add(nextUp.id);
    }

    final problems = <String>[];
    final warnings = <String>[];
    String describe(ItemId other) {
      final planned = snapshot[other];
      return planned == null ? '$other (missing)' : '$other (${planned.item.status})';
    }

    // Dependencies outside the epic; those of the epic itself hold up all of it.
    final outsideNoted = <ItemId>{};
    List<String> outside(PlannedItem planned) {
      final waits = <String>[];
      for (final dependency in [...epic.item.dependsOn, ...planned.item.dependsOn]) {
        if (dependency == id || descendants.contains(dependency)) continue;
        final other = snapshot[dependency];
        if (other != null && other.isDone) continue;
        waits.add(describe(dependency));
        if (!outsideNoted.add(dependency)) continue;
        final owner = epic.item.dependsOn.contains(dependency) ? id : planned.id;
        if (other == null) {
          problems.add('$owner depends on $dependency, which does not exist.');
        } else if (other.category == StatusCategory.open && workflow.status(other.item.status)?.pickable != true) {
          problems.add('$owner depends on ${describe(dependency)}, which is not done and not even planned.');
        } else {
          warnings.add('$owner waits for ${describe(dependency)} outside the epic; the agent stops there and asks.');
        }
      }
      return waits;
    }

    final members = <EpicMember>[];
    for (final planned in ordered) {
      final state = states[planned.id]!;
      if (!inScope(planned.id)) {
        members.add(EpicMember(item: planned, state: state, inScope: false));
        continue;
      }
      final claimedByOther = planned.isClaimed && planned.claim!.agent != agent;
      if (state == EpicMemberState.inProgress && claimedByOther) {
        warnings.add('${planned.id} is in progress, claimed by ${planned.claim!.agent}; the items after it wait.');
      }
      if (state != EpicMemberState.remaining) {
        members.add(EpicMember(item: planned, state: state));
        continue;
      }
      // Across the scope's border: the agent would wait for an item it never takes.
      for (final other in before(planned)) {
        if (states[other]!.settled || inScope(other)) continue;
        final kind = planned.item.dependsOn.contains(other) ? 'depends on' : 'has the open child';
        problems.add(
          '${planned.id} ($milestone) $kind ${describe(other)} of ${snapshot[other]!.item.milestone}, outside the '
          'scope $milestone: implement that milestone too (or all of it).',
        );
      }
      final waits = outside(planned);
      if (planned.category == null) {
        waits.add('its unknown status ${planned.item.status}');
        warnings.add('${planned.id} has the unknown status ${planned.item.status}.');
      }
      if (planned.needsHuman) {
        waits.add("a person's answer to its question");
        warnings.add('${planned.id} waits for a person to answer its question.');
      }
      final conflicts = [
        for (final other in planned.conflictsWith)
          if (other != id && !descendants.contains(other)) other,
      ];
      if (conflicts.isNotEmpty) {
        waits.add('${conflicts.join(', ')} (touches the same files)');
        warnings.add('${planned.id} touches the same files as ${conflicts.map(describe).join(', ')}, in progress.');
      }
      if (claimedByOther) {
        waits.add('the claim of ${planned.claim!.agent}');
        warnings.add('${planned.id} is claimed by ${planned.claim!.agent}.');
      }
      members.add(
        EpicMember(
          item: planned,
          state: state,
          after: [
            for (final other in before(planned))
              if (!states[other]!.settled) other,
          ],
          waits: waits,
        ),
      );
    }

    for (final cycle in snapshot.dependencyCycles()) {
      if (cycle.any(descendants.contains)) {
        problems.add('The dependencies ${[...cycle, cycle.first].join(' → ')} form a cycle.');
      }
    }
    if (epic.isDone) problems.insert(0, '$id is already ${epic.item.status}.');
    if (epic.isClaimed && epic.claim!.agent != agent) problems.add('$id is claimed by ${epic.claim!.agent}.');
    final scoped = members.where((m) => m.inScope);
    if (members.isEmpty) {
      problems.add('$id has no child items to implement.');
    } else if (scoped.isEmpty) {
      problems.add('$id has no items in $milestone (or without a milestone).');
    } else if (scoped.every((m) => m.state.settled)) {
      problems.add(
        milestone == null
            ? 'Nothing left to implement: every item of $id is handed over or done.'
            : 'Nothing left to implement in $milestone: every item of $id in it is handed over or done.',
      );
    }

    final groups = <String?, List<EpicMember>>{};
    for (final member in members) {
      (groups[member.item.item.milestone] ??= []).add(member);
    }
    final milestones = groups.keys.toList();
    int rank(String? milestone) =>
        milestone == null ? workflow.milestones.length + 1 : workflow.milestoneRank(milestone);
    mergeSort(milestones, compare: (a, b) => rank(a).compareTo(rank(b)));

    final own = epic.item.branch?.trim();
    return EpicPlan._(
      epic: epic,
      branch: own == null || own.isEmpty ? 'agent/$id' : own,
      members: List.unmodifiable(members),
      problems: List.unmodifiable(problems),
      warnings: List.unmodifiable(warnings),
      progress: List.unmodifiable([
        for (final key in milestones)
          EpicMilestoneProgress(
            milestone: key,
            settled: groups[key]!.where((m) => m.state.settled).length,
            total: groups[key]!.length,
          ),
      ]),
      agent: agent,
      milestone: milestone,
    );
  }

  final PlannedItem epic;

  /// The branch all of it is implemented on: the epic's `branch`, else
  /// `agent/<id>`.
  final String branch;

  /// Every item under the epic, in the order they can be done.
  final List<EpicMember> members;

  /// Why it cannot start; empty when it can.
  final List<String> problems;

  /// What the agent will probably have to stop and ask about.
  final List<String> warnings;

  /// Whose claims count as the implementing agent's own.
  final String? agent;

  /// The milestone this run implements (with the items without one); null
  /// for all items of the epic.
  final String? milestone;

  /// Items outside [milestone] that are not handed over or done: this run
  /// leaves them as they are.
  List<EpicMember> get skipped => [
    for (final member in members)
      if (!member.inScope && !member.state.settled) member,
  ];

  /// How far the items are per milestone, in the workflow's order of
  /// milestones (those without one last), whatever the scope.
  final List<EpicMilestoneProgress> progress;

  ItemId get id => epic.id;

  EpicVerdict get verdict => problems.isNotEmpty
      ? EpicVerdict.forbidden
      : warnings.isNotEmpty
      ? EpicVerdict.warning
      : EpicVerdict.ok;

  /// An item in progress that nobody else holds: the agent goes on with it
  /// before it takes a new one.
  EpicMember? get current => members.firstWhereOrNull(
    (m) => m.inScope && m.state == EpicMemberState.inProgress && (!m.item.isClaimed || m.item.claim!.agent == agent),
  );

  /// What the agent takes next: [current], else the first item that can
  /// start; null when nothing can.
  EpicMember? get next => current ?? members.firstWhereOrNull((m) => m.canStart);

  /// Every item (in [milestone]) is handed over or done.
  bool get finished => members.any((m) => m.inScope) && members.where((m) => m.inScope).every((m) => m.state.settled);

  /// How many items are in [state].
  int count(EpicMemberState state) => members.where((m) => m.state == state).length;
}
