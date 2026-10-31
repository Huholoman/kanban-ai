import '../../claims/domain/claim.dart';
import '../../items/domain/item_repository.dart';
import '../../shared/clock.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/backlog_snapshot.dart';
import '../domain/branch_changes.dart';
import '../domain/review_state.dart';

/// Builds [BacklogSnapshot]s from the current state of storage.
final class PlanningService {
  PlanningService({
    required ItemRepository items,
    required ClaimStore claims,
    required Workflow workflow,
    required Clock clock,
    BranchHeads? branches,
    BranchChanges? changes,
  }) : _branches = branches,
       _changes = changes,
       _items = items,
       _claims = claims,
       _workflow = workflow,
       _clock = clock;

  final ItemRepository _items;
  final ClaimStore _claims;
  final Workflow _workflow;
  final Clock _clock;
  final BranchHeads? _branches;
  final BranchChanges? _changes;

  Future<BacklogSnapshot> snapshot() async {
    final catalog = await _items.load();
    final heads = await _branches?.heads() ?? const <String, BranchHead>{};
    final active = {
      for (final item in catalog.items)
        if (_workflow.categoryOf(item.status) == StatusCategory.active) BacklogSnapshot.branchOf(item),
    };
    return BacklogSnapshot.build(
      items: catalog.items,
      workflow: _workflow,
      claims: await _claims.all(),
      now: _clock.now(),
      branchHeads: heads,
      changedFiles: active.isEmpty ? const {} : await _changes?.changedFiles(heads, active) ?? const {},
    );
  }
}
