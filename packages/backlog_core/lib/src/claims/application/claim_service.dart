import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_repository.dart';
import '../../planning/application/planning_service.dart';
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
  /// Refuses blocked items, items with open children and finished items
  /// unless [force] is set. Claiming an item the agent already holds just
  /// renews the claim.
  Future<ClaimOutcome> claim(String reference, String agent, {bool force = false}) async {
    agent = Claim.validateAgent(agent);
    final snapshot = await _planning.snapshot();
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    if (!force) _checkClaimable(planned);
    return _acquire(planned, agent);
  }

  /// Claims the most urgent ready item that matches [where]; null when there
  /// is nothing to do. Safe to call from many agents at once: an item someone
  /// else grabbed in the meantime is skipped.
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

  Future<ClaimOutcome> _acquire(PlannedItem planned, String agent) async {
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

    try {
      final item = planned.item.copyWith(
        status: planned.category == StatusCategory.open ? _workflow.activeStatus : null,
        assignee: () => agent,
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
