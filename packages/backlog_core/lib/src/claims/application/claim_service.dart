import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_repository.dart';
import '../../planning/application/planning_service.dart';
import '../../planning/domain/epic_plan.dart';
import '../../planning/domain/planned_item.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/claim.dart';

final class ClaimOutcome {
  const ClaimOutcome(this.item, this.claim, {this.tookOver});

  final Item item;
  final Claim claim;

  /// The expired claim this one replaced, if any.
  final Claim? tookOver;
}

/// How agents take work: claim an item, keep the claim alive, hand it back
/// or finish it. The lock decides who wins; the item file only mirrors it
/// (status and assignee) so that humans see who works on what.
final class ClaimService {
  ClaimService({
    required ItemRepository items,
    required ClaimStore claims,
    required PlanningService planning,
    required Workflow workflow,
    required Clock clock,
  }) : _items = items,
       _claims = claims,
       _planning = planning,
       _workflow = workflow,
       _clock = clock;

  final ItemRepository _items;
  final ClaimStore _claims;
  final PlanningService _planning;
  final Workflow _workflow;
  final Clock _clock;

  Future<List<Claim>> all() => _claims.all();

  /// Claims the item for [agent] and moves it to the active status.
  ///
  /// Refuses blocked items, items waiting for overlapping work in progress,
  /// items with open children and finished items unless [force] is set. Claiming an item the agent already holds just
  /// renews the claim. Without [mirror] only the lock is taken and the item
  /// file is left as it is (status, assignee): an action that works on an
  /// item without taking it over.
  Future<ClaimOutcome> claim(String reference, String agent, {bool force = false, bool mirror = true}) async {
    agent = Claim.validateAgent(agent);
    final snapshot = await _planning.snapshot();
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    if (!force) _checkClaimable(planned);
    return _acquire(planned, agent, mirror: mirror);
  }

  /// Claims the most urgent ready item that matches [where]; null when there
  /// is nothing to do. Safe to call from many agents at once: an item someone
  /// else grabbed in the meantime is skipped. Overlapping `touches` are
  /// judged on the snapshot, so two agents calling this at the same moment
  /// may still take two overlapping open items.
  Future<ClaimOutcome?> claimNext(String agent, {bool Function(PlannedItem item)? where}) async {
    agent = Claim.validateAgent(agent);
    final snapshot = await _planning.snapshot();
    for (final candidate in snapshot.ready) {
      if (where != null && !where(candidate)) continue;
      try {
        return await _acquire(candidate, agent);
      } on ClaimConflictException {
        continue;
      }
    }
    return null;
  }

  /// The implementation of the epic [reference] as [agent] sees it
  /// ([EpicPlan]).
  Future<EpicPlan> epic(String reference, {String? agent}) async {
    final snapshot = await _planning.snapshot();
    return EpicPlan.of(
      snapshot,
      ItemReference.resolve(reference, snapshot.ids),
      agent: agent == null ? null : Claim.validateAgent(agent),
    );
  }

  /// Claims the next item of the epic [reference] for [agent]
  /// ([EpicPlan.next]: the one it has in progress, else the first that can
  /// start) and puts it on the epic's branch ([EpicPlan.branch]); items of
  /// the epic that are handed over count as done for it, so it is claimed
  /// even when the snapshot calls it blocked. Returns the plan and the
  /// claim, which is null when nothing can start.
  Future<({EpicPlan plan, ClaimOutcome? outcome})> claimInEpic(String reference, String agent) async {
    agent = Claim.validateAgent(agent);
    final plan = await epic(reference, agent: agent);
    if (plan.epic.isDone) throw InvalidInputException('${plan.id} is already ${plan.epic.item.status}.');
    final next = plan.next;
    if (next == null) return (plan: plan, outcome: null);
    return (plan: plan, outcome: await _acquire(next.item, agent, branch: plan.branch));
  }

  /// Extends the claim so that it does not expire while work continues.
  Future<Claim> heartbeat(String reference, String agent) async {
    agent = Claim.validateAgent(agent);
    final id = await _resolve(reference);
    final current = await _claims.find(id);
    if (current == null || current.agent != agent) {
      throw ClaimConflictException(
        current == null ? '$id is not claimed.' : '$id is claimed by ${current.agent}, not $agent.',
      );
    }
    final renewed = current.heartbeat(_clock.now());
    await _claims.refresh(renewed);
    return renewed;
  }

  /// Gives the item back unfinished: drops the claim and returns an active
  /// item to the pickable status (or to [status]).
  Future<Item> release(String reference, {String? agent, String? status, bool force = false}) async {
    final item = await _item(reference);
    final claim = await _checkHolder(item.id, agent, force);
    final target =
        status ?? (_workflow.categoryOf(item.status) == StatusCategory.active ? _workflow.pickableStatus : item.status);
    _checkStatus(target);
    final released = item.copyWith(
      status: target,
      assignee: item.assignee == claim?.agent ? () => null : null,
      updated: () => _today,
    );
    await _items.save(released);
    await _claims.remove(item.id);
    return released;
  }

  /// Drops the claim of [agent] and leaves the item as it is (status and
  /// assignee), e.g. once an agent handed its work over for review. Nothing
  /// happens when [agent] does not hold the claim.
  Future<bool> drop(String reference, String agent) async {
    agent = Claim.validateAgent(agent);
    final id = await _resolve(reference);
    final claim = await _claims.find(id);
    if (claim == null || claim.agent != agent) return false;
    await _claims.remove(id);
    return true;
  }

  /// Removes the lock of item [id] whoever holds it, without touching the
  /// item (which may not exist): the fix of a stale or orphaned lock. False
  /// when there was none.
  Future<bool> removeLock(ItemId id) async {
    if (await _claims.find(id) == null) return false;
    await _claims.remove(id);
    return true;
  }

  /// Marks the item done (or another done-category [status]) and drops the
  /// claim. The assignee stays as a record of who did it.
  Future<Item> complete(String reference, {String? agent, String? status, bool force = false}) async {
    final item = await _item(reference);
    await _checkHolder(item.id, agent, force);
    final target = status ?? _workflow.doneStatus;
    _checkStatus(target);
    if (_workflow.categoryOf(target) != StatusCategory.done) {
      throw InvalidInputException('"$target" is not a done status.');
    }
    final finished = item.copyWith(status: target, assignee: agent == null ? null : () => agent, updated: () => _today);
    await _items.save(finished);
    await _claims.remove(item.id);
    return finished;
  }

  /// Marks the unfinished items under [epic] whose work is on [branch]
  /// (their `branch` field) done, whoever holds them: the epic was merged
  /// with them. Returns their ids.
  Future<List<ItemId>> completeMembers(ItemId epic, String branch) async {
    final snapshot = await _planning.snapshot();
    final done = <ItemId>[];
    for (final planned in snapshot.items) {
      if (planned.isDone || !planned.ancestors.contains(epic) || planned.item.branch?.trim() != branch) continue;
      await complete(planned.id.value, force: true);
      done.add(planned.id);
    }
    return done;
  }

  /// After [id]'s [branch] was merged: the unfinished items under it whose
  /// work is on [branch] are done ([completeMembers]), and [id] itself is
  /// done only when no unfinished item remains under it. Otherwise (an epic
  /// deployed in part) it stays in its status, loses its claim and its `pr`
  /// (merged; the next Implement epic opens a new one) and [remaining] lists
  /// what is left.
  Future<({List<ItemId> members, List<ItemId> remaining})> completeMerged(ItemId id, String branch) async {
    final members = await completeMembers(id, branch);
    final remaining = [
      for (final planned in (await _planning.snapshot()).items)
        if (!planned.isDone && planned.ancestors.contains(id)) planned.id,
    ];
    if (remaining.isEmpty) {
      await complete(id.value, force: true);
    } else {
      final item = await _item(id.value);
      await _items.save(item.copyWith(pr: () => null, updated: () => _today));
      await _claims.remove(id);
    }
    return (members: members, remaining: remaining);
  }

  /// The ancestor of [id] whose branch [branch] is (its `branch`, else
  /// `agent/<ancestor>`) when other unfinished items under that ancestor
  /// have their work on [branch] too: merging [id] alone would bring theirs
  /// along, so the ancestor (the epic) is the one to deploy. Null otherwise.
  Future<({ItemId epic, List<ItemId> others})?> sharedEpicBranch(ItemId id, String branch) async {
    final snapshot = await _planning.snapshot();
    final planned = snapshot[id];
    if (planned == null) return null;
    for (final ancestor in planned.ancestors) {
      final own = snapshot[ancestor]?.item.branch?.trim();
      if ((own == null || own.isEmpty ? 'agent/$ancestor' : own) != branch) continue;
      final others = [
        for (final other in snapshot.items)
          if (other.id != id &&
              !other.isDone &&
              other.ancestors.contains(ancestor) &&
              other.item.branch?.trim() == branch)
            other.id,
      ];
      return others.isEmpty ? null : (epic: ancestor, others: others);
    }
    return null;
  }

  Future<ClaimOutcome> _acquire(PlannedItem planned, String agent, {bool mirror = true, String? branch}) async {
    final id = planned.id;
    final now = _clock.now();
    final fresh = Claim(itemId: id, agent: agent, claimedAt: now, heartbeatAt: now, lease: _workflow.claimLease);

    Claim claim = fresh;
    Claim? tookOver;
    final existing = await _claims.find(id);
    if (existing != null && existing.agent == agent) {
      claim = existing.heartbeat(now);
      await _claims.refresh(claim);
    } else if (existing != null && !existing.isExpiredAt(now)) {
      throw ClaimConflictException(
        '$id is claimed by ${existing.agent} until ${existing.expiresAt.toIso8601String()}.',
      );
    } else if (existing != null) {
      if (!await _claims.tryReplace(existing, fresh)) {
        throw ClaimConflictException('$id was just claimed by another agent.');
      }
      tookOver = existing;
    } else if (!await _claims.tryAcquire(fresh)) {
      final holder = await _claims.find(id);
      throw ClaimConflictException('$id was just claimed by ${holder?.agent ?? 'another agent'}.');
    }

    if (!mirror) return ClaimOutcome(planned.item, claim, tookOver: tookOver);
    try {
      final item = planned.item.copyWith(
        status: planned.category == StatusCategory.open ? _workflow.activeStatus : null,
        assignee: () => agent,
        branch: branch == null ? null : () => branch,
        updated: () => formatDay(now),
      );
      await _items.save(item);
      return ClaimOutcome(item, claim, tookOver: tookOver);
    } catch (_) {
      if (claim == fresh) await _claims.remove(id);
      rethrow;
    }
  }

  void _checkClaimable(PlannedItem planned) {
    final id = planned.id;
    if (planned.isDone) {
      throw InvalidInputException('$id is already ${planned.item.status}.');
    }
    if (planned.isBlocked) {
      throw InvalidInputException(
        '$id is blocked by ${[...planned.openDependencies, ...planned.missingDependencies].join(', ')}; use --force to claim anyway.',
      );
    }
    if (planned.isConflicting) {
      throw InvalidInputException(
        '$id touches the same files as ${planned.conflictsWith.join(', ')}, which is in progress; '
        'wait for it or use --force.',
      );
    }
    if (planned.openChildCount > 0) {
      throw InvalidInputException(
        '$id has ${planned.openChildCount} open child item(s); claim one of those, or use --force.',
      );
    }
  }

  /// Returns the current claim when [agent] may act on it.
  Future<Claim?> _checkHolder(ItemId id, String? agent, bool force) async {
    final claim = await _claims.find(id);
    if (claim == null || force || claim.isExpiredAt(_clock.now())) return claim;
    if (agent == null || claim.agent != Claim.validateAgent(agent)) {
      throw ClaimConflictException('$id is claimed by ${claim.agent}; pass --as ${claim.agent} or --force.');
    }
    return claim;
  }

  void _checkStatus(String status) {
    if (_workflow.status(status) == null) {
      throw InvalidInputException('Unknown status "$status".');
    }
  }

  Future<ItemId> _resolve(String reference) async =>
      ItemReference.resolve(reference, (await _items.load()).items.map((i) => i.id));

  Future<Item> _item(String reference) async {
    final items = (await _items.load()).items;
    final id = ItemReference.resolve(reference, items.map((i) => i.id));
    return items.firstWhere((i) => i.id == id);
  }

  String get _today => formatDay(_clock.now());
}
