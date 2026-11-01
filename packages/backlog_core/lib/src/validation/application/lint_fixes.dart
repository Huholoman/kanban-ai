import '../../claims/application/claim_service.dart';
import '../../items/application/field_change.dart';
import '../../items/application/item_service.dart';
import '../../items/domain/item_id.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/lint_issue.dart';

/// One way to fix a lint issue; [apply] changes the item or the claim.
final class LintFix {
  const LintFix(this.label, this.apply);

  final String label;
  final Future<void> Function() apply;
}

/// The fixes offered for lint issues: an unknown status, priority, type or
/// milestone is set to a known one (a milestone may also be cleared), a
/// reference to a missing item or to the item itself is removed, an expired
/// claim is released (the item goes back to the pickable status), a stale
/// or orphaned lock is removed. Other issues have none.
final class LintFixer {
  LintFixer({required ItemService items, required ClaimService claims, required Workflow workflow})
    : _items = items,
      _claims = claims,
      _workflow = workflow;

  final ItemService _items;
  final ClaimService _claims;
  final Workflow _workflow;

  List<LintFix> fixes(LintIssue issue) {
    final item = issue.item;
    if (item == null) return const [];
    LintFix set(String field, String value, String label) =>
        LintFix(label, () => _items.update(item, [FieldChange(field, ChangeOp.set, value)]));
    return switch ((issue.code, issue.field, issue.value)) {
      ('unknown-status' || 'unknown-priority' || 'unknown-type', final field?, _) => [
        for (final value in switch (field) {
          'status' => [for (final status in _workflow.statuses) status.id],
          'priority' => _workflow.priorities,
          _ => _workflow.types,
        })
          set(field, value, 'Set $field to $value'),
      ],
      ('unknown-milestone', _, _) => [
        for (final milestone in _workflow.milestones)
          set('milestone', milestone.id, 'Set milestone to ${milestone.id}'),
        set('milestone', '', 'Clear the milestone'),
      ],
      ('dangling-reference' || 'self-reference', 'parent', _) => [set('parent', '', 'Clear parent')],
      ('dangling-reference' || 'self-reference', final field?, final value?) => [
        LintFix('Remove $value from $field', () => _items.update(item, [FieldChange(field, ChangeOp.remove, value)])),
      ],
      ('expired-claim', _, _) => [
        LintFix(
          'Release $item (an active item goes back to ${_workflow.pickableStatus})',
          () => _claims.release(item, force: true),
        ),
      ],
      ('stale-claim' || 'orphan-claim', _, _) => [LintFix('Remove the lock', () => _claims.removeLock(ItemId(item)))],
      _ => const [],
    };
  }
}
