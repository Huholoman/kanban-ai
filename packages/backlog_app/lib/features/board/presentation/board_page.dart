import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_scope.dart';
import '../../item/presentation/item_page.dart';
import '../application/board_controller.dart';
import 'filter_bar.dart';
import 'new_item_dialog.dart';
import 'view_layouts.dart';

/// Main screen. On a wide window: saved views on the left, the board in the
/// middle and the open item in a panel on the right. Narrow windows pick the
/// view from the app bar and open items as a full page.
class BoardPage extends StatefulWidget {
  const BoardPage({super.key});

  /// From this width the views get a side panel.
  static const sideNavigationWidth = 900.0;

  /// From this width items open next to the board instead of over it.
  static const detailPanelWidth = 1200.0;

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  BoardController? _controller;
  StreamSubscription<String>? _notices;

  /// Item open in the right panel.
  String? _selectedId;

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

  Future<void> _open(String id) async {
    if (_hasDetailPanel) {
      setState(() => _selectedId = id);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ItemPage(reference: id)));
    unawaited(_controller?.refresh(quiet: true));
  }

  void _closeDetail() => setState(() => _selectedId = null);

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
    final selectedId = width >= BoardPage.detailPanelWidth ? _selectedId : null;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeDetail},
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
                _LintButton(issues: controller.lint, onOpen: _open),
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
                  _ViewsPanel(controller: controller, onCreate: () => _create(controller)),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: _body(controller, selectedId)),
                if (selectedId != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: (width * 0.36).clamp(440, 640),
                    child: ItemDetailView(
                      key: ValueKey(selectedId),
                      reference: selectedId,
                      onOpen: _open,
                      onClose: _closeDetail,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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

IconData _layoutIcon(ViewLayoutDto layout) => switch (layout) {
  ViewLayoutDto.kanban => Icons.view_kanban_outlined,
  ViewLayoutDto.graph => Icons.account_tree_outlined,
  ViewLayoutDto.table => Icons.table_rows_outlined,
  ViewLayoutDto.list => Icons.list,
};

/// Saved views as a list on the left: views without a section first, then
/// foldable sections. Each view's menu moves it to another section.
class _ViewsPanel extends StatelessWidget {
  const _ViewsPanel({required this.controller, required this.onCreate});

  final BoardController controller;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final sections = controller.viewSections;
    return SizedBox(
      width: 220,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: FilledButton.tonalIcon(
              onPressed: controller.workflow == null ? null : onCreate,
              icon: const Icon(Icons.add),
              label: const Text('New item'),
            ),
          ),
          for (final (name, members) in sections)
            if (name == null) ...[
              const _SectionHeader(title: 'Views'),
              for (final view in members) _tile(context, view),
            ],
          for (final (name, members) in sections)
            if (name != null) ...[
              _SectionHeader(
                key: ValueKey('section-$name'),
                title: name,
                collapsed: controller.collapsedSections.contains(name),
                onToggle: () => controller.toggleSection(name),
              ),
              if (!controller.collapsedSections.contains(name))
                for (final view in members) _tile(context, view),
            ],
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, ViewSummaryDto view) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        key: ValueKey('view-${view.id}'),
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        selected: view.id == controller.selectedViewId,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        leading: Icon(_layoutIcon(view.layout), size: 20),
        title: Text(view.name),
        trailing: MenuAnchor(
          menuChildren: [
            MenuItemButton(
              key: ValueKey('move-view-${view.id}'),
              leadingIcon: const Icon(Icons.drive_file_move_outline, size: 18),
              onPressed: () => _move(context, view),
              child: const Text('Move to section…'),
            ),
          ],
          builder: (context, menu, _) => IconButton(
            key: ValueKey('view-menu-${view.id}'),
            tooltip: 'View options',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.more_vert),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
        ),
        onTap: () => unawaited(controller.selectView(view.id)),
      ),
    );
  }

  Future<void> _move(BuildContext context, ViewSummaryDto view) async {
    final section = await showDialog<String>(
      context: context,
      builder: (_) => _SectionDialog(view: view, sections: controller.sectionNames),
    );
    if (section != null) await controller.moveView(view.id, section);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title, this.collapsed = false, this.onToggle});

  final String title;
  final bool collapsed;

  /// Null for the heading of views without a section, which cannot fold.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final toggle = onToggle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: toggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: style, overflow: TextOverflow.ellipsis),
              ),
              if (toggle != null)
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18, color: style?.color),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for the section of [view]: an existing one, a new name, or none.
/// Pops the name, '' for no section, or null when cancelled.
class _SectionDialog extends StatefulWidget {
  const _SectionDialog({required this.view, required this.sections});

  final ViewSummaryDto view;
  final List<String> sections;

  @override
  State<_SectionDialog> createState() => _SectionDialogState();
}

class _SectionDialogState extends State<_SectionDialog> {
  late final _name = TextEditingController(text: widget.view.section ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Move "${widget.view.name}"'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('section-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Section', hintText: 'New or existing section'),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
          if (widget.sections.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final section in widget.sections)
                  ActionChip(label: Text(section), onPressed: () => Navigator.of(context).pop(section)),
              ],
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (widget.view.section != null)
        TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('Remove from section')),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(_name.text.trim()), child: const Text('Move')),
    ],
  );
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
                children: [Icon(_layoutIcon(view.layout), size: 20), const SizedBox(width: 8), Text(view.name)],
              ),
            ),
        ],
        onChanged: (id) => id == null ? null : unawaited(controller.selectView(id)),
      ),
    );
  }
}

class _LintButton extends StatelessWidget {
  const _LintButton({required this.issues, required this.onOpen});

  final List<LintIssueDto> issues;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final errors = issues.where((i) => i.isError).length;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: issues.isEmpty ? 'Lint: all good' : 'Lint: ${issues.length} issue(s)',
      onPressed: issues.isEmpty ? null : () => _show(context),
      icon: Badge(
        isLabelVisible: issues.isNotEmpty,
        backgroundColor: errors > 0 ? scheme.error : Colors.orange,
        label: Text('${issues.length}'),
        child: Icon(issues.isEmpty ? Icons.verified_outlined : Icons.rule),
      ),
    );
  }

  void _show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Lint'),
      content: SizedBox(
        width: 640,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final issue in issues)
              ListTile(
                dense: true,
                leading: Icon(
                  issue.isError ? Icons.error_outline : Icons.warning_amber,
                  color: issue.isError ? Theme.of(context).colorScheme.error : Colors.orange,
                ),
                title: Text(issue.message),
                subtitle: Text([issue.code, ?issue.item, ?issue.location].join(' · ')),
                onTap: issue.item == null
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        onOpen(issue.item!);
                      },
              ),
          ],
        ),
      ),
    ),
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
