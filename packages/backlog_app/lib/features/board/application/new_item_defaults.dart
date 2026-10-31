import 'package:backlog_api/backlog_api.dart';

/// What a new item starts with in the *New item* dialog.
abstract final class NewItemDefaults {
  /// The usual levels of a hierarchy, each the child type of the one before.
  static const levels = ['epic', 'story', 'task', 'subtask'];

  /// The type a new child of a [parentType] item starts with: an epic gets a
  /// story, a story a task, a task a subtask — each when the workflow knows
  /// that type. Without a level below, a task (or subtask) gets its own type;
  /// anything else gets the workflow's default type.
  static String childType(String parentType, WorkflowDto workflow) {
    final level = levels.indexOf(parentType);
    if (level < 0) return workflow.defaultType;
    if (level + 1 < levels.length && workflow.types.contains(levels[level + 1])) return levels[level + 1];
    if (level >= levels.indexOf('task') && workflow.types.contains(parentType)) return parentType;
    return workflow.defaultType;
  }

  /// Items a new item can be put under, for the dialog's parent search:
  /// unfinished ones, higher levels first (epics, stories, …), then by id.
  static List<ItemDto> parentCandidates(Iterable<ItemDto> items) {
    int rank(ItemDto item) => switch (levels.indexOf(item.type)) {
      -1 => levels.length,
      final level => level,
    };
    return items.where((item) => !item.isDone).toList()
      ..sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : a.id.compareTo(b.id));
  }

  /// [candidates] whose id or title contains [query] (any case), at most
  /// [limit] of them.
  static List<ItemDto> search(List<ItemDto> candidates, String query, {int limit = 20}) {
    final text = query.trim().toLowerCase();
    return candidates
        .where(
          (item) => text.isEmpty || item.id.toLowerCase().contains(text) || item.title.toLowerCase().contains(text),
        )
        .take(limit)
        .toList();
  }
}
