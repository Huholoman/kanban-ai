import 'package:backlog_api/backlog_api.dart';

/// One row of a board column: an item card, possibly indented under its parent.
final class ColumnEntry {
  const ColumnEntry(this.item, {this.depth = 0, this.isContext = false, this.descendants = 0, this.collapsed = false});

  final ItemDto item;

  /// Nesting under parents shown above it in the same column.
  final int depth;

  /// The item itself is in another column (or outside the view); it is shown
  /// only as a header, so that its children here are seen as belonging to it.
  final bool isContext;

  /// Items nested under this one in the column, shown or not.
  final int descendants;

  /// Its [descendants] are folded away.
  final bool collapsed;

  @override
  bool operator ==(Object other) =>
      other is ColumnEntry &&
      other.item.id == item.id &&
      other.depth == depth &&
      other.isContext == isContext &&
      other.descendants == descendants &&
      other.collapsed == collapsed;

  @override
  int get hashCode => Object.hash(item.id, depth, isContext, descendants, collapsed);

  @override
  String toString() =>
      '${'  ' * depth}${item.id}${isContext ? ' (context)' : ''}${collapsed ? ' (+$descendants collapsed)' : ''}';
}

/// Orders the items of one column as a tree by `parent`.
///
/// Children follow their parent, indented. A parent that is not in the
/// column appears as a context header above its children — so an epic shows
/// on top of its stories in every column where it has some. Roots keep the
/// order of the view (the position of their first item). Entries whose id is
/// in [collapsed] keep their row but hide everything nested under them.
abstract final class ColumnArrangement {
  static List<ColumnEntry> arrange(
    List<ItemDto> items,
    Map<String, ItemDto> index, {
    Set<String> collapsed = const {},
  }) {
    final inColumn = {for (final item in items) item.id: item};
    final children = <String, List<ItemDto>>{};
    final roots = <String>[]; // ids, in order of first appearance
    final rootSet = <String>{};

    void addRoot(String id) {
      if (rootSet.add(id)) roots.add(id);
    }

    for (final item in items) {
      final parent = item.parent;
      if (parent == null || parent == item.id) {
        addRoot(item.id);
        continue;
      }
      (children[parent] ??= []).add(item);
      if (!inColumn.containsKey(parent)) addRoot(parent); // context header
    }
    // Items in a parent cycle within the column would never be reached.
    final reachable = <String>{};

    final entries = <ColumnEntry>[];
    void visit(String id, int depth) {
      if (!reachable.add(id)) return;
      final item = inColumn[id];
      if (item != null) {
        entries.add(ColumnEntry(item, depth: depth));
      } else {
        entries.add(ColumnEntry(index[id] ?? _missing(id), depth: depth, isContext: true));
      }
      for (final child in children[id] ?? const <ItemDto>[]) {
        visit(child.id, depth + 1);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    for (final item in items) {
      if (!reachable.contains(item.id)) visit(item.id, 0);
    }
    return _fold(entries, collapsed);
  }

  /// Counts descendants (the following deeper rows) and drops the folded ones.
  static List<ColumnEntry> _fold(List<ColumnEntry> entries, Set<String> collapsed) {
    final result = <ColumnEntry>[];
    int? foldedDepth;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (foldedDepth != null && entry.depth > foldedDepth) continue;
      foldedDepth = null;
      var descendants = 0;
      while (i + descendants + 1 < entries.length && entries[i + descendants + 1].depth > entry.depth) {
        descendants++;
      }
      final folded = descendants > 0 && collapsed.contains(entry.item.id);
      if (folded) foldedDepth = entry.depth;
      result.add(
        ColumnEntry(
          entry.item,
          depth: entry.depth,
          isContext: entry.isContext,
          descendants: descendants,
          collapsed: folded,
        ),
      );
    }
    return result;
  }

  static ItemDto _missing(String id) => ItemDto(id: id, title: '(missing item)', type: '?', status: '?', priority: '');
}
