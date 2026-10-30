import 'dart:async';
import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_scope.dart';
import '../../../app/appearance_controller.dart';
import '../../item/presentation/item_page.dart';
import '../application/board_controller.dart';
import '../application/detail_trail.dart';
import 'columns_dialog.dart';
import 'filter_bar.dart';
import 'new_item_dialog.dart';
import 'save_view_dialog.dart';
import 'shell/view_navigation.dart';
import 'view_layouts.dart';

/// Main screen. On a wide window: saved views on the left, the board in the
/// middle and the open item in a panel on the right. Children opened from
/// that panel get further panels to the right (an epic, its story, the
/// story's task, …); when they do not fit, the board and the oldest panels
/// give way to a breadcrumb. Narrow windows pick the
/// view from the app bar and open items as a full page.
class BoardPage extends StatefulWidget {
  const BoardPage({super.key});

  /// From this width the views get a side panel.
  static const sideNavigationWidth = 900.0;

  /// From this width items open next to the board instead of over it.
  static const detailPanelWidth = 1200.0;

  /// Narrowest detail panel when several are open.
  static const minPanelWidth = 440.0;

  /// Narrowest board still shown next to several panels.
  static const minBoardWidth = 480.0;

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  BoardController? _controller;
  StreamSubscription<String>? _notices;

  /// Items open in panels on the right, left to right.
  DetailTrail _trail = DetailTrail.empty;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final controller = _controller = BoardController(AppScope.of(context).api);
    _notices = controller.notices.listen(_showNotice);
    unawaited(controller.start());
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    _controller?.dispose();
    super.dispose();
  }

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _hasDetailPanel => MediaQuery.sizeOf(context).width >= BoardPage.detailPanelWidth;

  /// Opens [id] from the board (a new trail) or from the panel at [from].
  Future<void> _open(String id, {int? from}) async {
    if (_hasDetailPanel) {
      setState(() => _trail = from == null ? _trail.open(id) : _trail.openFrom(from, id));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ItemPage(reference: id)));
    unawaited(_controller?.refresh(quiet: true));
  }

  Future<void> _saveFilterAsView(BoardController controller) async {
    final chosen = await showSaveViewDialog(
      context,
      suggestedName: '${_currentViewName(controller)} (filtered)',
      sections: controller.sectionNames,
    );
    if (chosen == null) return;
    final (name, section, pinned) = chosen;
    await controller.saveFilterAsView(name, section: section, pinned: pinned);
  }

  Future<void> _editColumns(BoardController controller) async {
    final result = controller.result;
    if (result?.groupBy == null) return;
    final chosen = await showColumnsDialog(
      context,
      field: result!.groupBy!,
      options: controller.columnOptions,
      shown: [
        for (final group in result.groups)
          if (group.key.isNotEmpty) group.key,
      ],
    );
    if (chosen != null) await controller.setColumns(chosen.isEmpty ? null : chosen);
  }

  void _closeLast() => setState(() => _trail = _trail.pop());

  Future<void> _create(BoardController controller) async {
    final workflow = controller.workflow;
    if (workflow == null) return;
    final request = await showNewItemDialog(context, workflow);
    if (request == null) return;
    final created = await controller.create(request);
    if (created != null && mounted) await _open(created.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final width = MediaQuery.sizeOf(context).width;
    final sideNavigation = width >= BoardPage.sideNavigationWidth;
    final trail = width >= BoardPage.detailPanelWidth ? _trail : DetailTrail.empty;
    final selectedId = trail.ids.firstOrNull;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeLast},
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Scaffold(
            appBar: AppBar(
              title: sideNavigation ? Text(_currentViewName(controller)) : _ViewPicker(controller: controller),
              actions: [
                if (controller.loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                if (controller.canEditColumns)
                  IconButton(
                    key: const ValueKey('edit-columns'),
                    tooltip: 'Columns of this view',
                    icon: const Icon(Icons.view_week_outlined),
                    onPressed: () => _editColumns(controller),
                  ),
                if (AppScope.of(context).appearance case final appearance?) _ModeButton(appearance: appearance),
                IconButton(
                  tooltip: 'Reload',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => unawaited(controller.refresh()),
                ),
                const SizedBox(width: 8),
              ],
            ),
            floatingActionButton: controller.workflow == null || sideNavigation
                ? null
                : FloatingActionButton.extended(
                    onPressed: () => _create(controller),
                    icon: const Icon(Icons.add),
                    label: const Text('New item'),
                  ),
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sideNavigation) ...[
                  SizedBox(
                    width: 220,
                    child: ViewNavigation(
                      controller: controller,
                      onCreate: () => _create(controller),
                      onOpenItem: _open,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => _content(controller, trail, selectedId, constraints.maxWidth),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The board and the detail panels in [available] width.
  Widget _content(BoardController controller, DetailTrail trail, String? selectedId, double available) {
    final count = trail.ids.length;
    if (count == 0) return _body(controller, selectedId);
    if (count == 1) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _body(controller, selectedId)),
          const VerticalDivider(width: 1),
          SizedBox(width: (available * 0.4).clamp(BoardPage.minPanelWidth, 640), child: _panel(trail, 0)),
        ],
      );
    }
    final besideBoard = ((available - BoardPage.minBoardWidth) / BoardPage.minPanelWidth).floor();
    if (besideBoard >= count) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _body(controller, selectedId)),
          for (var i = 0; i < count; i++) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: BoardPage.minPanelWidth, child: _panel(trail, i)),
          ],
        ],
      );
    }
    // Panels only; what does not fit goes to the breadcrumb.
    final first = trail.firstShown(max(1, (available / BoardPage.minPanelWidth).floor()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Breadcrumb(
          trail: trail,
          hidden: first,
          index: controller.index,
          onBoard: () => setState(() => _trail = DetailTrail.empty),
          onOpen: (i) => setState(() => _trail = trail.closeFrom(i + 1)),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = first; i < count; i++) ...[
                if (i > first) const VerticalDivider(width: 1),
                Expanded(child: _panel(trail, i)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _panel(DetailTrail trail, int index) {
    final id = trail.ids[index];
    return ItemDetailView(
      key: ValueKey('panel-$index-$id'),
      reference: id,
      openChildId: trail.nextAfter(index),
      onOpen: (target) => _open(target, from: index),
      onClose: () => setState(() => _trail = trail.closeFrom(index)),
    );
  }

  static String _currentViewName(BoardController controller) =>
      controller.views.where((view) => view.id == controller.selectedViewId).firstOrNull?.name ?? 'Backlog';

  Widget _body(BoardController controller, String? selectedId) {
    final result = controller.visible;
    if (result == null) {
      if (controller.error != null) return _ErrorView(error: controller.error!, onRetry: controller.refresh);
      if (controller.loading) return const Center(child: CircularProgressIndicator());
      return const Center(child: Text('No views in this backlog.'));
    }
    return Column(
      children: [
        if (controller.error != null)
          MaterialBanner(
            content: Text('Showing older data: ${controller.error}'),
            actions: [TextButton(onPressed: controller.refresh, child: const Text('Retry'))],
          ),
        FilterBar(
          filter: controller.filter,
          options: controller.filterOptions,
          shown: controller.counts.shown,
          total: controller.counts.total,
          onChanged: controller.setFilter,
          onSaveAsView: () => _saveFilterAsView(controller),
          index: controller.index,
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (result.layout) {
            ViewLayoutDto.kanban => KanbanBoard(
              result: result,
              workflow: controller.workflow,
              index: controller.index,
              selectedId: selectedId,
              onOpen: _open,
              onMove: controller.canMove ? (item, key) => unawaited(controller.move(item, key)) : null,
              collapsed: controller.collapsed,
              onToggleCollapsed: controller.toggleCollapsed,
            ),
            _ => GroupedItemList(
              result: result,
              workflow: controller.workflow,
              index: controller.index,
              selectedId: selectedId,
              onOpen: _open,
            ),
          },
        ),
        if (result.hidden > 0)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('${result.hidden} more item(s) outside the shown columns.'),
          ),
      ],
    );
  }
}

/// Way back when the board and earlier panels have no room: the board, then
/// the hidden items of the trail.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.trail,
    required this.hidden,
    required this.index,
    required this.onBoard,
    required this.onOpen,
  });

  final DetailTrail trail;

  /// How many panels from the left are not shown.
  final int hidden;
  final Map<String, ItemDto> index;
  final VoidCallback onBoard;

  /// Shows the trail up to the item at this position.
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final separator = Icon(Icons.chevron_right, size: 18, color: muted);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('crumb-board'),
            onPressed: onBoard,
            icon: const Icon(Icons.view_kanban_outlined, size: 18),
            label: const Text('Board'),
          ),
          for (var i = 0; i < hidden; i++) ...[
            separator,
            TextButton(
              key: ValueKey('crumb-${trail.ids[i]}'),
              onPressed: () => onOpen(i),
              child: Text(index[trail.ids[i]]?.title ?? trail.ids[i], overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),
    );
  }
}

class _ViewPicker extends StatelessWidget {
  const _ViewPicker({required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.views.isEmpty) return const Text('Backlog');
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('view-picker'),
        value: controller.selectedViewId,
        style: Theme.of(context).textTheme.titleLarge,
        items: [
          for (final view in controller.views)
            DropdownMenuItem(
              value: view.id,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [Icon(layoutIcon(view.layout), size: 20), const SizedBox(width: 8), Text(view.name)],
              ),
            ),
        ],
        onChanged: (id) => id == null ? null : unawaited(controller.selectView(id)),
      ),
    );
  }
}

/// Switches between the system, light and dark look for this session.
class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.appearance});

  final AppearanceController appearance;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appearance,
    builder: (context, _) {
      final (icon, label) = switch (appearance.mode) {
        ThemeMode.system => (Icons.brightness_auto_outlined, 'system'),
        ThemeMode.light => (Icons.light_mode_outlined, 'light'),
        ThemeMode.dark => (Icons.dark_mode_outlined, 'dark'),
      };
      return IconButton(
        key: const ValueKey('theme-mode'),
        tooltip: 'Theme: $label (click to switch)',
        icon: Icon(icon),
        onPressed: appearance.cycleMode,
      );
    },
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final unauthorized = error is BacklogApiException && (error as BacklogApiException).type == 'unauthorized';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text('$error', textAlign: TextAlign.center),
            if (unauthorized) const Text('Open the URL printed by the server, including ?token=…'),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
