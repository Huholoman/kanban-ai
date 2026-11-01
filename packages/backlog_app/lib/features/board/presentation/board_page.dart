import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../../dispatch/application/dispatch_controller.dart';
import '../../dispatch/presentation/dispatch_scope.dart';
import '../../item/presentation/item_page.dart';
import '../../projects/presentation/preview_banner.dart';
import '../application/board_controller.dart';
import '../application/new_item_defaults.dart';
import 'columns_dialog.dart';
import 'filter_bar.dart';
import 'new_item_dialog.dart';
import 'save_view_dialog.dart';
import 'shell/board_header.dart';
import 'shell/view_navigation.dart';
import 'view_layouts.dart';

/// Main screen. On a wide window: saved views on the left, the board in the
/// middle and the open item in a panel on the right. Medium windows have the
/// views as tabs and show the open item in a bottom sheet over the board;
/// phones have a bottom bar with the pinned views and open items as a page.
class BoardPage extends StatefulWidget {
  const BoardPage({super.key});

  /// From this width the views get a side panel; below it they are tabs
  /// (and a drawer with the full navigation).
  static const sideNavigationWidth = 1200.0;

  /// Below this width the phone layout applies: a bottom bar with the pinned
  /// views and the board one column at a time.
  static const phoneWidth = 600.0;

  /// From this width items open next to the board.
  static const detailPanelWidth = 1200.0;

  /// From this width items open in a sheet over the board; narrower windows
  /// use a full page.
  static const detailSheetWidth = 840.0;

  /// From this width the navigation is wider.
  static const veryWideWidth = 2000.0;

  /// Width of the detail panel in a window [windowWidth] wide: 38 % of it,
  /// at least 520 and at most 860 px.
  static double detailPanelWidthFor(double windowWidth) => (windowWidth * 0.38).clamp(520.0, 860.0);

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  BoardController? _controller;
  DispatchController? _dispatch;
  StreamSubscription<String>? _notices;
  StreamSubscription<String>? _dispatchNotices;

  /// Focus of the search field in the header; the `/` key moves it there.
  final _searchFocus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();

  /// The item shown in the detail panel or sheet.
  String? _openId;

  /// Whether the phone header shows the filter toolbar (other layouts always do).
  bool _filterOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final scope = AppScope.of(context);
    final api = scope.api;
    final projects = scope.projects;
    final controller = _controller = BoardController(api, onViewChosen: projects?.rememberView);
    _notices = controller.notices.listen(_showNotice);
    // The view last chosen in this project; a deleted one falls back to the default.
    unawaited(controller.start(viewId: projects?.lastView));
    final dispatch = _dispatch = DispatchController(api);
    _dispatchNotices = dispatch.notices.listen(_showNotice);
    unawaited(dispatch.start());
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    unawaited(_dispatchNotices?.cancel());
    _controller?.dispose();
    _dispatch?.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens [id] in the panel or sheet, or as a page on narrow windows.
  Future<void> _open(String id) async {
    if (MediaQuery.sizeOf(context).width >= BoardPage.detailSheetWidth) {
      setState(() => _openId = id);
      return;
    }
    await _openPage(id);
  }

  Future<void> _openPage(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DispatchScope(
          controller: _dispatch!,
          child: ItemPage(
            reference: id,
            onAddChild: (parent) => unawaited(_create(_controller!, parent: parent)),
            milestone: _controller?.milestone,
          ),
        ),
      ),
    );
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

  /// `/` jumps to the search unless the user is typing somewhere.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.slash) return KeyEventResult.ignored;
    final typing = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>();
    if (typing != null) return KeyEventResult.ignored;
    if (_filterOpen || MediaQuery.sizeOf(context).width >= BoardPage.phoneWidth) {
      _searchFocus.requestFocus();
    } else {
      // The phone header shows the search first.
      setState(() => _filterOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    }
    return KeyEventResult.handled;
  }

  void _closeDetail() => setState(() => _openId = null);

  /// The *New item* dialog, under [parent] when given; opens the new item.
  Future<void> _create(BoardController controller, {ItemDto? parent}) async {
    final workflow = controller.workflow;
    if (workflow == null) return;
    final request = await showNewItemDialog(
      context,
      workflow,
      candidates: NewItemDefaults.parentCandidates(controller.index.values),
      parent: parent,
    );
    if (request == null) return;
    final created = await controller.create(request);
    if (created != null && mounted) await _open(created.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final width = MediaQuery.sizeOf(context).width;
    final sideNavigation = width >= BoardPage.sideNavigationWidth;
    final phone = width < BoardPage.phoneWidth;
    final panel = width >= BoardPage.detailPanelWidth;
    final sheet = !panel && width >= BoardPage.detailSheetWidth;
    final veryWide = width >= BoardPage.veryWideWidth;
    final openId = panel || sheet ? _openId : null;
    return DispatchScope(
      controller: _dispatch!,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeDetail},
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Scaffold(
              key: _scaffold,
              drawer: sideNavigation
                  ? null
                  : Drawer(
                      child: ViewNavigation(
                        controller: controller,
                        onCreate: () {
                          _scaffold.currentState?.closeDrawer();
                          unawaited(_create(controller));
                        },
                        onOpenItem: (id) {
                          _scaffold.currentState?.closeDrawer();
                          unawaited(_open(id));
                        },
                        onNavigate: () => _scaffold.currentState?.closeDrawer(),
                      ),
                    ),
              bottomNavigationBar: phone
                  ? PinnedBottomBar(controller: controller, onMore: () => _scaffold.currentState?.openDrawer())
                  : null,
              floatingActionButton: controller.workflow == null || sideNavigation || openId != null
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
                      width: veryWide ? 240 : 208,
                      child: ViewNavigation(
                        controller: controller,
                        onCreate: () => _create(controller),
                        onOpenItem: _open,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (AppScope.of(context).preview case final preview?) PreviewBanner(controller: preview),
                        BoardHeader(
                          controller: controller,
                          filter: controller.visible == null ? null : _filterBar(controller),
                          onEditColumns: () => _editColumns(controller),
                          compact: phone,
                          filterOpen: _filterOpen,
                          onToggleFilter: () => setState(() => _filterOpen = !_filterOpen),
                          onMenu: sideNavigation ? null : () => _scaffold.currentState?.openDrawer(),
                        ),
                        if (!sideNavigation && !phone) ViewTabs(controller: controller),
                        Expanded(child: _board(controller, openId, sheet: sheet)),
                      ],
                    ),
                  ),
                  if (panel && openId != null) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: BoardPage.detailPanelWidthFor(width),
                      child: _detail(openId, onClose: _closeDetail, onScope: controller.scopeToEpic),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The item detail; it navigates to parents, siblings and children itself.
  Widget _detail(String reference, {VoidCallback? onClose, void Function(String epicId)? onScope}) => ItemDetailView(
    key: ValueKey('detail-$reference'),
    reference: reference,
    onClose: onClose,
    onScope: onScope,
    onAddChild: (parent) => unawaited(_create(_controller!, parent: parent)),
    milestone: _controller?.milestone,
  );

  /// The board; with [sheet] the open item is a bottom sheet over it.
  Widget _board(BoardController controller, String? openId, {required bool sheet}) {
    final body = _body(controller, openId);
    if (!sheet || openId == null) return body;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: constraints.maxHeight * 0.45,
            child: _DetailSheet(
              onOpenFull: () => unawaited(_openPage(openId)),
              child: _detail(openId, onClose: _closeDetail, onScope: controller.scopeToEpic),
            ),
          ),
        ],
      ),
    );
  }

  static String _currentViewName(BoardController controller) =>
      controller.views.where((view) => view.id == controller.selectedViewId).firstOrNull?.name ?? 'Backlog';

  /// The filter toolbar of the header.
  Widget _filterBar(BoardController controller) => FilterBar(
    filter: controller.filter,
    options: controller.filterOptions,
    shown: controller.counts.shown,
    total: controller.counts.total,
    onChanged: controller.setFilter,
    onSaveAsView: () => _saveFilterAsView(controller),
    index: controller.index,
    counts: controller.filterCounts,
    searchFocus: _searchFocus,
  );

  Widget _body(BoardController controller, String? selectedId) {
    final result = controller.visible;
    if (result == null) {
      if (controller.error != null) return _ErrorView(error: controller.error!, onRetry: controller.refresh);
      if (controller.loading) return const Center(child: CircularProgressIndicator());
      return const Center(child: Text('No views in this backlog.'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.error != null)
          MaterialBanner(
            content: Text('Showing older data: ${controller.error}'),
            actions: [LinkButton(label: 'Retry', onPressed: controller.refresh)],
          ),
        Expanded(
          child: switch (result.layout) {
            ViewLayoutDto.kanban => KanbanBoard(
              paged: MediaQuery.sizeOf(context).width < BoardPage.phoneWidth,
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
            child: Text('${result.hidden} more item(s) outside the shown columns.', textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

/// The open item over the lower part of the board: rounded top corners, a
/// drag handle and a button that opens the item as a full page.
class _DetailSheet extends StatelessWidget {
  const _DetailSheet({required this.child, required this.onOpenFull});

  final Widget child;
  final VoidCallback onOpenFull;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Material(
      key: const ValueKey('detail-sheet'),
      color: tokens.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: tokens.borderStrong, borderRadius: BorderRadius.circular(2)),
                ),
                Positioned(
                  right: 4,
                  child: IconButton(
                    key: const ValueKey('open-full'),
                    tooltip: 'Open full screen',
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    color: tokens.muted,
                    icon: const Icon(Icons.open_in_full),
                    onPressed: onOpenFull,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
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
            PrimaryButton(label: 'Retry', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
