import 'dart:async';
import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../../dispatch/presentation/action_buttons.dart';
import '../application/column_arrangement.dart';
import 'item_card.dart';

typedef OpenItem = void Function(String id);
typedef MoveItem = void Function(ItemDto item, String key);

/// Columns side by side; cards can be dragged between them when [onMove] is
/// set. Inside a column, children are indented under their parent (see
/// [ColumnArrangement]). With [stacked] (phones) the columns become status
/// sections one under another, without drag and drop.
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
    this.paged = false,
  });

  static const minColumnWidth = 196.0;
  static const maxColumnWidth = 280.0;
  static const columnGap = 12.0;
  static const pagePadding = 16.0;
  static const indent = 10.0;

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

  /// Phone layout: one column at a time, swiped sideways, with a column
  /// switcher on top; cards move by long-press → "Move to…".
  final bool paged;

  /// Column width for [count] columns in [available] pixels: they share the
  /// width, within [minColumnWidth] and [maxColumnWidth].
  static double columnWidthFor(double available, int count) {
    if (count <= 0) return minColumnWidth;
    final share = (available - 2 * pagePadding - columnGap * (count - 1)) / count;
    return share.clamp(minColumnWidth, maxColumnWidth);
  }

  /// The whole board scrolls vertically like a page; columns grow with
  /// their cards and reach at least the bottom of the window, so there is
  /// always room to drop a card.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (paged) return _PagedBoard(board: this);
        final width = columnWidthFor(constraints.maxWidth, result.groups.length);
        return _PageScroll(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, group) in result.groups.indexed) ...[
                if (i > 0) const SizedBox(width: columnGap),
                _column(context, group, width, max(0, constraints.maxHeight - 2 * pagePadding)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _column(BuildContext context, ViewGroupDto group, double width, double minHeight) {
    final tokens = BoardTokens.of(context);
    final entries = ColumnArrangement.arrange(group.items, index, collapsed: collapsed);

    Widget column(bool highlighted) => SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupHeader(result: result, group: group, workflow: workflow),
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: BoxConstraints(minHeight: max(0, minHeight - 30)),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: highlighted ? tokens.accentSoft : tokens.well,
              borderRadius: BorderRadius.circular(BoardTokens.radius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in entries)
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: _entry(context, entry, width)),
              ],
            ),
          ),
        ],
      ),
    );

    final move = onMove;
    if (move == null) return column(false);
    return DragTarget<ItemDto>(
      onWillAcceptWithDetails: (details) => !group.items.any((i) => i.id == details.data.id),
      onAcceptWithDetails: (details) => move(details.data, group.key),
      builder: (context, candidates, _) => column(candidates.isNotEmpty),
    );
  }

  Widget _entry(
    BuildContext context,
    ColumnEntry entry,
    double columnWidth, {
    bool draggable = true,
    VoidCallback? onLongPress,
  }) {
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
        onLongPress: onLongPress,
        footer: toggle,
        menu: CardActionsMenu(item: item, workflow: workflow),
      );
      content = onMove == null || !draggable
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

/// The phone board: one column per page, swiped sideways. A switcher on top
/// shows the column (‹ todo · 7 ›) and a row of all columns to jump to.
class _PagedBoard extends StatefulWidget {
  const _PagedBoard({required this.board});

  final KanbanBoard board;

  @override
  State<_PagedBoard> createState() => _PagedBoardState();
}

class _PagedBoardState extends State<_PagedBoard> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int page) {
    setState(() => _page = page);
    unawaited(_pages.animateToPage(page, duration: const Duration(milliseconds: 220), curve: Curves.easeOut));
  }

  @override
  Widget build(BuildContext context) {
    final board = widget.board;
    final groups = board.result.groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final page = _page.clamp(0, groups.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColumnSwitcher(board: board, page: page, onSelect: _go),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (page) => setState(() => _page = page),
            children: [for (final group in groups) _column(context, group)],
          ),
        ),
      ],
    );
  }

  Widget _column(BuildContext context, ViewGroupDto group) {
    final board = widget.board;
    final entries = ColumnArrangement.arrange(group.items, board.index, collapsed: board.collapsed);
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Nothing in ${group.key.isEmpty ? '(none)' : group.key}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView(
      key: PageStorageKey('page-${group.key}'),
      padding: const EdgeInsets.all(KanbanBoard.pagePadding),
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: board._entry(
              context,
              entry,
              0,
              draggable: false,
              onLongPress: board.onMove == null || entry.isContext ? null : () => _moveSheet(entry.item, group.key),
            ),
          ),
      ],
    );
  }

  /// "Move X-7f3a to" with the other columns; picking one sets the field the
  /// view groups by, like a drop on the desktop.
  Future<void> _moveSheet(ItemDto item, String from) async {
    final board = widget.board;
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Move ${item.id} to', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final group in board.result.groups)
              if (group.key != from)
                ListTile(
                  key: ValueKey('move-to-${group.key}'),
                  title: Text(group.key.isEmpty ? '(none)' : group.key),
                  trailing: Text('${group.items.length}'),
                  onTap: () => Navigator.of(context).pop(group.key),
                ),
          ],
        ),
      ),
    );
    if (target != null) board.onMove?.call(item, target);
  }
}

/// ‹ todo · 7 › above the phone board, and below it every column as a chip
/// (name and count) to jump to.
class _ColumnSwitcher extends StatelessWidget {
  const _ColumnSwitcher({required this.board, required this.page, required this.onSelect});

  final KanbanBoard board;
  final int page;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final groups = board.result.groups;
    final current = groups[page];
    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconActionButton(
                key: const ValueKey('page-previous'),
                tooltip: 'Previous column',
                icon: Icons.chevron_left,
                onPressed: page > 0 ? () => onSelect(page - 1) : null,
              ),
              Expanded(
                child: _GroupHeader(result: board.result, group: current, workflow: board.workflow, centered: true),
              ),
              IconActionButton(
                key: const ValueKey('page-next'),
                tooltip: 'Next column',
                icon: Icons.chevron_right,
                onPressed: page < groups.length - 1 ? () => onSelect(page + 1) : null,
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final (index, group) in groups.indexed)
                  _KeptVisible(
                    visible: index == page,
                    child: ChoiceChip(
                      key: ValueKey('page-${group.key}'),
                      label: Text('${group.key.isEmpty ? '(none)' : group.key}  ${group.items.length}'),
                      selected: index == page,
                      showCheckmark: false,
                      onSelected: (_) => onSelect(index),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Scrolls [child] into view when it becomes [visible] (the current column's
/// chip in the switcher row).
class _KeptVisible extends StatefulWidget {
  const _KeptVisible({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_KeptVisible> createState() => _KeptVisibleState();
}

class _KeptVisibleState extends State<_KeptVisible> {
  @override
  void didUpdateWidget(_KeptVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 200)));
      });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(right: 6), child: widget.child);
}

/// Title of a column or section with the number of items, e.g. `Backlog  4`.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.result, required this.group, required this.workflow, this.centered = false});

  final ViewResultDto result;
  final ViewGroupDto group;
  final WorkflowDto? workflow;

  /// In the phone's column switcher: name and count side by side, centred.
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BoardTokens.of(context);
    final accent = ItemStyle.group(result.groupBy, group.key, workflow, theme.colorScheme);
    return Padding(
      padding: centered ? EdgeInsets.zero : const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Row(
        mainAxisAlignment: centered ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              group.key.isEmpty ? '(none)' : group.key,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (centered) const SizedBox(width: 8) else const Spacer(),
          Text('${group.items.length}', style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted)),
        ],
      ),
    );
  }
}

/// A parent shown above its children in a column it is not in itself: a
/// muted line `↑ Title`, so that the children read as its part.
class ParentHeader extends StatelessWidget {
  const ParentHeader({super.key, required this.item, this.workflow, this.onTap, this.trailing});

  final ItemDto item;
  final WorkflowDto? workflow;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BoardTokens.of(context);
    return Row(
      key: ValueKey('parent-${item.id}'),
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Text(
                '↑ ${item.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted, fontSize: 11),
              ),
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Scrolls [child] with draggable scrollbars: vertically like a page, and
/// horizontally when the columns are wider than the window. Scrollbars need
/// their own controllers to be draggable with the mouse.
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
      padding: const EdgeInsets.all(KanbanBoard.pagePadding),
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
    final tokens = BoardTokens.of(context);
    return Tooltip(
      message: collapsed ? 'Show nested items' : 'Hide nested items',
      child: InkWell(
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: tokens.muted),
              Text(
                collapsed ? '$count hidden' : '$count',
                style: theme.textTheme.labelSmall?.copyWith(color: tokens.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Indents a child under its parent.
class _Indented extends StatelessWidget {
  const _Indented({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: KanbanBoard.indent * depth),
    child: child,
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
    final grouped = result.groupBy != null;
    final showDependencies = result.layout == ViewLayoutDto.graph;
    return ListView(
      padding: const EdgeInsets.all(KanbanBoard.pagePadding),
      children: [
        for (final group in result.groups)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (grouped) _GroupHeader(result: result, group: group, workflow: workflow),
                  for (final item in group.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ItemCard(
                            item: item,
                            workflow: workflow,
                            showStatus: result.groupBy != 'status',
                            selected: item.id == selectedId,
                            onTap: () => onOpen(item.id),
                            menu: CardActionsMenu(item: item, workflow: workflow),
                          ),
                          if (showDependencies && item.dependsOn.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 16, top: 4),
                              child: DependencyTree(ids: item.dependsOn, index: index, onOpen: onOpen, path: {item.id}),
                            ),
                        ],
                      ),
                    ),
                  SizedBox(height: grouped ? 8 : 0),
                ],
              ),
            ),
          ),
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
    final tokens = BoardTokens.of(context);
    final item = widget.index[widget.id];
    final cycle = widget.path.contains(widget.id);
    final nested = item?.dependsOn ?? const <String>[];
    final canExpand = nested.isNotEmpty && !cycle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('dependency-${widget.id}'),
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
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
                          color: tokens.muted,
                          tooltip: _expanded ? 'Collapse' : 'Show what it needs',
                          icon: Icon(_expanded ? Icons.expand_more : Icons.chevron_right),
                          onPressed: () => setState(() => _expanded = !_expanded),
                        )
                      : Center(
                          child: Text('└', style: TextStyle(height: 1, color: tokens.faint)),
                        ),
                ),
                Icon(
                  item?.isDone ?? false ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 14,
                  color: item == null ? tokens.danger : ItemStyle.category(item.category, scheme),
                ),
                const SizedBox(width: 6),
                Text(widget.id, style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted, fontSize: 11)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item == null ? '(missing item)' : item.title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (cycle) Tag('cycle', color: tokens.danger),
                if (item != null) ...[const SizedBox(width: 8), Tag(item.status)],
                if (item?.blocked ?? false) ...[
                  const SizedBox(width: 4),
                  Tag('blocked', icon: Icons.block, color: tokens.warning),
                ],
                if (item?.conflicting ?? false) ...[
                  const SizedBox(width: 4),
                  Tag('waiting', icon: Icons.hourglass_empty, color: tokens.warning),
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
