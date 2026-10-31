import '../../planning/domain/planned_item.dart';

/// Fields a view can filter, sort and group by. Besides the front-matter keys
/// there are computed ones: `ready`, `blocked`, `conflicting`, `conflicts_with`,
/// `claimed`, `claimed_by`, `needs_human`,
/// `category`, `has_children`, `ancestors` (parent chain) and `epic` (the
/// epics among the item and its ancestors). Any other name reads an unknown front-matter
/// key, so custom fields work without code changes.
abstract final class ItemFields {
  static const computed = [
    'ready',
    'blocked',
    'conflicting',
    'conflicts_with',
    'claimed',
    'claimed_by',
    'needs_human',
    'category',
    'has_children',
    'ancestors',
    'epic',
  ];

  /// All values of [field] as strings; empty when the item has none.
  static List<String> valuesOf(PlannedItem planned, String field) {
    final item = planned.item;
    return switch (field) {
      'id' => [item.id.value],
      'title' => [item.title],
      'type' => [item.type],
      'status' => [item.status],
      'priority' => [item.priority],
      'milestone' => [?item.milestone],
      'parent' => [?item.parent?.value],
      'depends_on' => [for (final id in item.dependsOn) id.value],
      'related' => [for (final id in item.related) id.value],
      'assignee' => [?item.assignee],
      'branch' => [?item.branch],
      'pr' => [?item.pr],
      'labels' => item.labels,
      'docs' => item.docs,
      'touches' => item.touches,
      'created' => [?item.created],
      'updated' => [?item.updated],
      'ready' => ['${planned.isReady}'],
      'blocked' => ['${planned.isBlocked}'],
      'conflicting' => ['${planned.isConflicting}'],
      'conflicts_with' => [for (final id in planned.conflictsWith) id.value],
      'claimed' => ['${planned.isClaimed}'],
      'claimed_by' => [if (planned.isClaimed) planned.claim!.agent],
      'needs_human' => ['${planned.needsHuman}'],
      'category' => [?planned.category?.name],
      'has_children' => ['${planned.childCount > 0}'],
      'ancestors' => [for (final id in planned.ancestors) id.value],
      'epic' => [for (final id in planned.epics) id.value],
      _ => switch (item.extra[field]) {
        null => const [],
        final List<Object?> list => [for (final v in list) '$v'],
        final Object value => ['$value'],
      },
    };
  }
}
