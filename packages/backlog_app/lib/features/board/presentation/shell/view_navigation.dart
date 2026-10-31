import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../../app/app_scope.dart';
import '../../../../shared/tokens.dart';
import '../../../../shared/ui/ui.dart';
import '../../../dashboard/application/dashboard_controller.dart';
import '../../../dashboard/presentation/dashboard_page.dart';
import '../../../dispatch/presentation/dispatch_overview.dart';
import '../../../projects/presentation/project_switcher.dart';
import '../../application/board_controller.dart';
import '../../application/board_filter.dart';
import 'lint_dialog.dart';

/// Icon of a view's layout.
IconData layoutIcon(ViewLayoutDto layout) => switch (layout) {
  ViewLayoutDto.kanban => Icons.view_kanban_outlined,
  ViewLayoutDto.graph => Icons.account_tree_outlined,
  ViewLayoutDto.table => Icons.table_rows_outlined,
  ViewLayoutDto.list => Icons.list,
};

/// The navigation: the project (a switcher with several projects), "New item", the saved views (those without a
/// section first, then foldable sections) and the lint summary at the bottom.
/// Each view's menu moves it to a section or pins it to the bottom bar.
/// Sized by its parent: a fixed side column or a drawer.
class ViewNavigation extends StatelessWidget {
  const ViewNavigation({
    super.key,
    required this.controller,
    required this.onCreate,
    required this.onOpenItem,
    this.onNavigate,
  });

  final BoardController controller;
  final VoidCallback onCreate;

  /// Opens an item chosen in the lint dialog or the agents overview.
  final void Function(String id) onOpenItem;

  /// Called after a view was chosen (closes the drawer).
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final sections = controller.viewSections;
    return Material(
      color: tokens.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(8, 10, 8, 6), child: ProjectSwitcher()),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: PrimaryButton(
              key: const ValueKey('new-item'),
              label: 'New item',
              icon: Icons.add,
              onPressed: controller.workflow == null ? null : onCreate,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (AppScope.of(context).dashboard case final dashboard?)
                  _DashboardRow(dashboard: dashboard, onNavigate: onNavigate),
                for (final (name, members) in sections)
                  if (name == null) ...[
                    const SectionLabel('Views'),
                    for (final view in members) _ViewRow(controller: controller, view: view, onNavigate: onNavigate),
                  ],
                for (final (name, members) in sections)
                  if (name != null) ...[
                    SectionLabel(
                      name,
                      key: ValueKey('section-$name'),
                      collapsed: controller.collapsedSections.contains(name),
                      onToggle: () => controller.toggleSection(name),
                    ),
                    if (!controller.collapsedSections.contains(name))
                      for (final view in members) _ViewRow(controller: controller, view: view, onNavigate: onNavigate),
                  ],
                if (controller.people case final people when people.isNotEmpty) ...[
                  const SectionLabel('People'),
                  for (final (agent, count) in people)
                    _PersonRow(controller: controller, agent: agent, count: count, onNavigate: onNavigate),
                ],
                DispatchOverview(onOpenItem: onOpenItem),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.border)),
            ),
            child: LintLink(issues: controller.lint, onOpenItem: onOpenItem),
          ),
        ],
      ),
    );
  }
}

class _ViewRow extends StatelessWidget {
  const _ViewRow({required this.controller, required this.view, this.onNavigate});

  final BoardController controller;
  final ViewSummaryDto view;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final selected = view.id == controller.selectedViewId;
    final count = view.count;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? tokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
        child: InkWell(
          key: ValueKey('view-${view.id}'),
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          onTap: () {
            unawaited(controller.selectView(view.id));
            onNavigate?.call();
          },
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    view.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? tokens.accent : tokens.text,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (count != null) CountText(count),
                _ViewMenu(controller: controller, view: view),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the dashboard; its badge counts what waits for a person in every
/// project.
class _DashboardRow extends StatelessWidget {
  const _DashboardRow({required this.dashboard, this.onNavigate});

  final DashboardController dashboard;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return ListenableBuilder(
      listenable: dashboard,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: InkWell(
          key: const ValueKey('open-dashboard'),
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          onTap: () {
            final navigator = Navigator.of(context);
            onNavigate?.call();
            unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => DashboardPage(controller: dashboard))));
          },
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.space_dashboard_outlined, size: 16, color: tokens.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Dashboard', style: TextStyle(color: tokens.text)),
                ),
                if (dashboard.needsMe > 0)
                  Tooltip(
                    message: '${dashboard.needsMe} waiting for you: questions, approvals, stopped work',
                    child: CountBadge(dashboard.needsMe, key: const ValueKey('dashboard-badge')),
                  ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An agent holding claims; a tap narrows the board to their items.
class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.controller, required this.agent, required this.count, this.onNavigate});

  final BoardController controller;
  final String agent;
  final int count;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final selected = controller.filter.valuesFor(FilterFacet.person).contains(agent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? tokens.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
        child: InkWell(
          key: ValueKey('person-$agent'),
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          onTap: () {
            controller.showPerson(agent);
            onNavigate?.call();
          },
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.smart_toy_outlined, size: 16, color: tokens.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    agent,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: selected ? tokens.accent : tokens.text),
                  ),
                ),
                CountText(count),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewMenu extends StatelessWidget {
  const _ViewMenu({required this.controller, required this.view});

  final BoardController controller;
  final ViewSummaryDto view;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        key: ValueKey('move-view-${view.id}'),
        leadingIcon: const Icon(Icons.drive_file_move_outline, size: 18),
        onPressed: () => _move(context),
        child: const Text('Move to section…'),
      ),
      MenuItemButton(
        key: ValueKey('pin-view-${view.id}'),
        leadingIcon: Icon(view.pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 18),
        onPressed: () => unawaited(controller.setPinned(view.id, !view.pinned)),
        child: Text(view.pinned ? 'Unpin from bottom bar' : 'Pin to bottom bar'),
      ),
    ],
    builder: (context, menu, _) => IconActionButton(
      key: ValueKey('view-menu-${view.id}'),
      tooltip: 'View options',
      icon: Icons.more_vert,
      size: 16,
      box: 28,
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
    ),
  );

  Future<void> _move(BuildContext context) async {
    final section = await showDialog<String>(
      context: context,
      builder: (_) => _SectionDialog(view: view, sections: controller.sectionNames),
    );
    if (section != null) await controller.moveView(view.id, section);
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
        LinkButton(label: 'Remove from section', onPressed: () => Navigator.of(context).pop('')),
      LinkButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
      PrimaryButton(label: 'Move', onPressed: () => Navigator.of(context).pop(_name.text.trim())),
    ],
  );
}

/// The views as a row of tabs for medium widths; the selected one is
/// underlined in the accent colour.
class ViewTabs extends StatelessWidget {
  const ViewTabs({super.key, required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final view in controller.views)
            InkWell(
              key: ValueKey('tab-${view.id}'),
              onTap: () => unawaited(controller.selectView(view.id)),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: view.id == controller.selectedViewId ? tokens.accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      view.name,
                      style: TextStyle(
                        color: view.id == controller.selectedViewId ? tokens.accent : tokens.text,
                        fontWeight: view.id == controller.selectedViewId ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (view.count != null) ...[const SizedBox(width: 6), CountText(view.count!)],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom bar of the phone: the pinned views (at most three; the first two
/// views when nothing is pinned) and "More", which opens the full navigation.
class PinnedBottomBar extends StatelessWidget {
  const PinnedBottomBar({super.key, required this.controller, required this.onMore});

  final BoardController controller;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final pinned = controller.pinnedViews;
    final shown = (pinned.isEmpty ? controller.views.take(2) : pinned.take(3)).toList();
    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (final view in shown)
                Expanded(
                  child: _BarItem(
                    key: ValueKey('bottom-view-${view.id}'),
                    icon: layoutIcon(view.layout),
                    label: view.name,
                    selected: view.id == controller.selectedViewId,
                    onTap: () => unawaited(controller.selectView(view.id)),
                  ),
                ),
              Expanded(
                child: _BarItem(
                  key: const ValueKey('bottom-more'),
                  icon: Icons.menu,
                  label: 'More',
                  selected: false,
                  onTap: onMore,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final color = selected ? tokens.accent : tokens.muted;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
          ),
        ],
      ),
    );
  }
}
