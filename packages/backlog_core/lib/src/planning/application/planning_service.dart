import '../../claims/domain/claim.dart';
import '../../items/domain/item_repository.dart';
import '../../shared/clock.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/backlog_snapshot.dart';
import '../domain/review_state.dart';

/// Builds [BacklogSnapshot]s from the current state of storage.
final class PlanningService {
  PlanningService({
    required ItemRepository items,
    required ClaimStore claims,
    required Workflow workflow,
    required Clock clock,
    BranchHeads? branches,
  }) : _branches = branches,
       _items = items,
       _claims = claims,
       _workflow = workflow,
       _clock = clock;

  final ItemRepository _items;
  final ClaimStore _claims;
  final Workflow _workflow;
  final Clock _clock;
  final BranchHeads? _branches;

  Future<BacklogSnapshot> snapshot() async {
    final catalog = await _items.load();
    return BacklogSnapshot.build(
      items: catalog.items,
      workflow: _workflow,
      claims: await _claims.all(),
      now: _clock.now(),
      branchHeads: await _branches?.heads() ?? const {},
    );
  }
}
