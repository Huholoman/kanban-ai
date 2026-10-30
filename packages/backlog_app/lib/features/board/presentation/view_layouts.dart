import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../application/column_arrangement.dart';
import 'item_card.dart';

typedef OpenItem = void Function(String id);
typedef MoveItem = void Function(ItemDto item, String key);

/// Columns side by side; cards can be dragged between them when [onMove] is
/// set. Inside a column, children are indented under their parent (see
/// [ColumnArrangement]).
class KanbanBoard extends StatelessWidget {
  const KanbanBoard({
    super.key,
    required this.result,
    this.workflow,
    this.index = const {},
    this.selectedId,
    required this.onOpen,
    this.onMove,
    this.collapsed = const {},
    this.onToggleCollapsed,
  });

  static const columnWidth = 300.0;
  static const indent = 14.0;

  final ViewResultDto result;
  final WorkflowDto? workflow;

  /// All items by id, for parents outside the column.
  final Map<String, ItemDto> index;
  final String? selectedId;
  final OpenItem onOpen;
  final MoveItem? onMove;

  /// Parents shown without their children.
  final Set<String> collapsed;
  final ValueChanged<String>? onToggleCollapsed;

  /// The whole board scrolls vertically like a page; columns grow with
  /// their cards and reach at least the bottom of the window, so there is
  /// always room to drop a card.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _PageScroll(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final group in result.groups)
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: max(0, constraints.maxHeight - 24)),
                child: _column(context, group),
              ),
          ],
        ),
      ),
    );
  }

  Widget _column(BuildContext context, ViewGroupDto group) {
    final theme = Theme.of(context);
    final accent = ItemStyle.group(result.groupBy, group.key, workflow, theme.colorScheme);
    final entries = ColumnArrangement.arrange(group.items, index, collapsed: collapsed);

    Widget cards(bool highlighted) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: columnWidth,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: highlighted ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(group.key.isEmpty ? '(none)' : group.key, style: theme.textTheme.titleSmall),
                const SizedBox(width: 6),
                Text('${group.items.length}', style: theme.textTheme.labelMedium?.copyWith(color: accent)),
              ],
            ),
          ),
          for (final entry in entries) _entry(context, entry),
        ],
      ),
    );

    final move = onMove;
    if (move == null) return cards(false);
    return DragTarget<ItemDto>(
      onWillAcceptWithDetails: (details) => !group.items.any((i) => i.id == details.data.id),
      onAcceptWithDetails: (details) => move(details.data, group.key),
      builder: (context, candidates, _) => cards(candidates.isNotEmpty),
    );
  }

  Widget _entry(BuildContext context, ColumnEntry entry) {
    final item = entry.item;
    final Widget content;
    final toggle = entry.descendants > 0 && onToggleCollapsed != null
        ? FoldToggle(
            key: ValueKey('fold-${item.id}'),
            collapsed: entry.collapsed,
            count: entry.descendants,
            onPressed: () => onToggleCollapsed!(item.id),
          )
        : null;
    if (entry.isContext) {
      content = ParentHeader(item: item, workflow: workflow, onTap: () => onOpen(item.id), trailing: toggle);
    } else {
      final card = ItemCard(
        item: item,
        workflow: workflow,
        selected: item.id == selectedId,
        onTap: () => onOpen(item.id),
        footer: toggle,
      );
      content = onMove == null
          ? card
          : Draggable<ItemDto>(
              data: item,
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: columnWidth - 16,
                  child: Opacity(opacity: 0.9, child: card),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: card),
              child: card,
            );
    }
    if (entry.depth == 0) return content;
    return _Indented(depth: entry.depth, child: content);
  }
}

/// A parent shown above its children in a column it is not in itself: a
/// slim header, so that the children read as its part.
class ParentHeader extends StatelessWidget {
  const ParentHeader({super.key, required this.item, this.workflow, this.onTap, this.trailing});

  final ItemDto item;
  final WorkflowDto? workflow;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: ValueKey('parent-${item.id}'),
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(ItemStyle.type(item.type), size: 14, color: ItemStyle.priority(item.priority, workflow)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                const SizedBox(width: 6),
                Text(item.status, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scrolls [child] both ways with draggable scrollbars: vertically like a
/// page, horizontally when the columns are wider than the window. Scrollbars
/// need their own controllers to be draggable with the mouse.
class _PageScroll extends StatefulWidget {
  const _PageScroll({required this.child});

  final Widget child;

  @override
  State<_PageScroll> createState() => _PageScrollState();
}

class _PageScrollState extends State<_PageScroll> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _vertical,
    thumbVisibility: true,
    interactive: true,
    child: SingleChildScrollView(
      controller: _vertical,
      padding: const EdgeInsets.all(12),
      child: Scrollbar(
        controller: _horizontal,
        interactive: true,
        child: SingleChildScrollView(controller: _horizontal, scrollDirection: Axis.horizontal, child: widget.child),
      ),
    ),
  );
}

/// Folds or unfolds the items nested under a parent in a column.
class FoldToggle extends StatelessWidget {
  const FoldToggle({super.key, required this.collapsed, required this.count, required this.onPressed});

  final bool collapsed;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: collapsed ? 'Show nested items' : 'Hide nested items',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16),
              Text(
                collapsed ? '$count hidden' : '$count',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Indents a child under its parent and draws a guide line on the left.
class _Indented extends StatelessWidget {
  const _Indented({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: KanbanBoard.indent * (depth - 1)),
    child: Container(
      padding: const EdgeInsets.only(left: KanbanBoard.indent - 2),
      margin: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 2)),
      ),
      child: child,
    ),
  );
}

/// Items one under another, with a header per group; also used for the
/// `table` and `graph` layouts (graph adds an expandable dependency tree).
class GroupedItemList extends StatelessWidget {
  const GroupedItemList({
    super.key,
    required this.result,
    this.workflow,
    this.index = const {},
    this.selectedId,
    required this.onOpen,
  });

  final ViewResultDto result;
  final WorkflowDto? workflow;
  final Map<String, ItemDto> index;
  final String? selectedId;
  final OpenItem onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = result.groupBy != null;
    final showDependencies = result.layout == ViewLayoutDto.graph;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        for (final group in result.groups) ...[
          if (grouped)
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Text(
                '${group.key.isEmpty ? '(none)' : group.key} · ${group.items.length}',
                style: theme.textTheme.titleSmall,
              ),
            ),
          for (final item in group.items)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ItemCard(
                      item: item,
                      workflow: workflow,
                      showStatus: result.groupBy != 'status',
                      selected: item.id == selectedId,
                      onTap: () => onOpen(item.id),
                    ),
                    if (showDependencies && item.dependsOn.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 6),
                        child: DependencyTree(ids: item.dependsOn, index: index, onOpen: onOpen, path: {item.id}),
                      ),
                  ],
                ),
              ),
            ),
        ],
        if (result.items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: Text('Nothing here.')),
          ),
      ],
    );
  }
}

/// What an item needs, as rows that open the dependency and expand into its
/// own dependencies.
class DependencyTree extends StatelessWidget {
  const DependencyTree({super.key, required this.ids, required this.index, required this.onOpen, this.path = const {}});

  final List<String> ids;
  final Map<String, ItemDto> index;
  final OpenItem onOpen;

  /// Items above in the tree; a dependency cycle stops here.
  final Set<String> path;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final id in ids) _DependencyRow(id: id, index: index, onOpen: onOpen, path: path)],
  );
}

class _DependencyRow extends StatefulWidget {
  const _DependencyRow({required this.id, required this.index, required this.onOpen, required this.path});

  final String id;
  final Map<String, ItemDto> index;
  final OpenItem onOpen;
  final Set<String> path;

  @override
  State<_DependencyRow> createState() => _DependencyRowState();
}

class _DependencyRowState extends State<_DependencyRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.index[widget.id];
    final cycle = widget.path.contains(widget.id);
    final nested = item?.dependsOn ?? const <String>[];
    final canExpand = nested.isNotEmpty && !cycle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('dependency-${widget.id}'),
          borderRadius: BorderRadius.circular(6),
          onTap: item == null ? null : () => widget.onOpen(widget.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: canExpand
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          tooltip: _expanded ? 'Collapse' : 'Show what it needs',
                          icon: Icon(_expanded ? Icons.expand_more : Icons.chevron_right),
                          onPressed: () => setState(() => _expanded = !_expanded),
                        )
                      : const Center(child: Text('└', style: TextStyle(height: 1))),
                ),
                Icon(
                  item?.isDone ?? false ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 16,
                  color: item == null ? scheme.error : ItemStyle.category(item.category, scheme),
                ),
                const SizedBox(width: 6),
                Text(widget.id, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item == null ? '(missing item)' : item.title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (cycle) Tag('cycle', color: scheme.error),
                if (item != null) ...[const SizedBox(width: 8), Tag(item.status)],
                if (item?.blocked ?? false) ...[
                  const SizedBox(width: 4),
                  Tag('blocked', icon: Icons.block, color: scheme.error),
                ],
              ],
            ),
          ),
        ),
        if (_expanded && canExpand)
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: DependencyTree(
              ids: nested,
              index: widget.index,
              onOpen: widget.onOpen,
              path: {...widget.path, widget.id},
            ),
          ),
      ],
    );
  }
}
