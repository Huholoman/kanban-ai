import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
import '../../workflow/domain/workflow.dart';
import 'filter.dart';
import 'item_fields.dart';

/// How a client should draw a view. The core only groups and sorts; drawing
/// is up to the CLI, the app or whoever renders it.
enum ViewLayout {
  list,
  kanban,
  table,
  graph;

  static ViewLayout? tryParse(String value) {
    for (final layout in values) {
      if (layout.name == value) return layout;
    }
    return null;
  }
}

final class SortKey {
  const SortKey(this.field, {this.descending = false});

  /// `priority`, or `-updated` for descending.
  factory SortKey.parse(String text) =>
      text.startsWith('-') ? SortKey(text.substring(1), descending: true) : SortKey(text);

  final String field;
  final bool descending;

  @override
  String toString() => descending ? '-$field' : field;
}

/// A saved query: which items, in what order, grouped how.
final class ViewDefinition {
  const ViewDefinition({
    required this.id,
    required this.name,
    this.layout = ViewLayout.list,
    this.filter = Filter.all,
    this.groupBy,
    this.columns,
    this.sort = const [],
    this.fields = const [],
    this.section,
    this.pinned = false,
  });

  final String id;
  final String name;
  final ViewLayout layout;

  /// Heading the view is listed under in the app; null for no section.
  final String? section;

  /// Shown in the phone's bottom bar.
  final bool pinned;

  /// The same view grouped by [field] instead (null: ungrouped). Columns
  /// belong to the original grouping, so they are dropped when it changes.
  ViewDefinition regroupedBy(String? field) => field == groupBy
      ? this
      : ViewDefinition(
          id: id,
          name: name,
          layout: layout,
          filter: filter,
          groupBy: field,
          sort: sort,
          fields: fields,
          section: section,
          pinned: pinned,
        );
  final Filter filter;
  final String? groupBy;

  /// Groups to show, in this order. Items in other groups are left out.
  /// When null, groups come from the workflow (status, priority) or from the
  /// values present.
  final List<String>? columns;
  final List<SortKey> sort;

  /// Extra fields a table or card should show.
  final List<String> fields;
}

final class ViewGroup {
  const ViewGroup(this.key, this.items);

  /// Empty string for items without a value (and for ungrouped views).
  final String key;
  final List<PlannedItem> items;
}

final class ViewResult {
  const ViewResult(this.definition, this.groups, {this.hidden = 0});

  final ViewDefinition definition;
  final List<ViewGroup> groups;

  /// Matching items that fall outside the listed [ViewDefinition.columns].
  final int hidden;

  List<PlannedItem> get items => [for (final group in groups) ...group.items];
}

/// Evaluates a [ViewDefinition] against a [BacklogSnapshot].
abstract final class ViewEngine {
  static ViewResult evaluate(ViewDefinition view, BacklogSnapshot snapshot) {
    final workflow = snapshot.workflow;
    final matching = snapshot.items.where(view.filter.matches).toList()
      ..sort((a, b) => _compare(view.sort, workflow, a, b));

    final groupBy = view.groupBy;
    if (groupBy == null) return ViewResult(view, [ViewGroup('', matching)]);

    final buckets = <String, List<PlannedItem>>{};
    for (final item in matching) {
      final keys = ItemFields.valuesOf(item, groupBy);
      for (final key in keys.isEmpty ? [''] : keys) {
        (buckets[key] ??= []).add(item);
      }
    }

    final keys = view.columns ?? _defaultKeys(groupBy, workflow, buckets.keys);
    final shown = {for (final key in keys) ...?buckets[key]};
    return ViewResult(view, [
      for (final key in keys) ViewGroup(key, buckets[key] ?? const []),
    ], hidden: matching.where((i) => !shown.contains(i)).length);
  }

  static List<String> _defaultKeys(String field, Workflow workflow, Iterable<String> present) {
    final known = switch (field) {
      'status' => workflow.statuses.map((s) => s.id).toList(),
      'priority' => workflow.priorities,
      'type' => workflow.types,
      'milestone' => workflow.milestones.map((m) => m.id).toList(),
      'category' => StatusCategory.values.map((c) => c.name).toList(),
      _ => <String>[],
    };
    final extra = present.where((k) => !known.contains(k) && k.isNotEmpty).toList()..sort();
    return [...known, ...extra, if (present.contains('')) ''];
  }

  static int _compare(List<SortKey> keys, Workflow workflow, PlannedItem a, PlannedItem b) {
    for (final key in keys) {
      final result = _compareField(key.field, workflow, a, b);
      if (result != 0) return key.descending ? -result : result;
    }
    return BacklogSnapshot.compareDefault(workflow, a, b);
  }

  static int _compareField(String field, Workflow workflow, PlannedItem a, PlannedItem b) {
    switch (field) {
      case 'priority':
        return workflow.priorityRank(a.item.priority).compareTo(workflow.priorityRank(b.item.priority));
      case 'status':
        return workflow.statusRank(a.item.status).compareTo(workflow.statusRank(b.item.status));
    }
    final left = ItemFields.valuesOf(a, field);
    final right = ItemFields.valuesOf(b, field);
    if (left.isEmpty || right.isEmpty) {
      return left.isEmpty == right.isEmpty ? 0 : (left.isEmpty ? 1 : -1);
    }
    return left.first.compareTo(right.first);
  }
}

/// Port for saved views.
abstract interface class ViewRepository {
  Future<ViewCatalog> load();

  /// Moves view [id] under [section]; null or blank removes the section.
  /// Everything else in the definition stays as written.
  Future<void> setSection(String id, String? section);

  /// Pins view [id] to the phone's bottom bar, or unpins it.
  Future<void> setPinned(String id, bool pinned);

  /// Sets which groups view [id] shows and in what order; null or empty
  /// goes back to the default groups.
  Future<void> setColumns(String id, List<String>? columns);

  /// The definition of view [id] as written (JSON-like), to derive others.
  Future<Map<String, Object?>> raw(String id);

  /// Saves a new view under an id derived from [preferredId] (made unique)
  /// and returns that id. [definition] uses the YAML format of views.
  Future<String> create(String preferredId, Map<String, Object?> definition);
}

final class ViewCatalog {
  const ViewCatalog(this.views, [this.problems = const []]);

  final List<ViewDefinition> views;

  /// `(file, message)` for definitions that could not be read.
  final List<(String, String)> problems;
}
