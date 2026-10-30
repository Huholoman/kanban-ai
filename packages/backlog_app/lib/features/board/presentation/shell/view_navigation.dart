import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../../shared/tokens.dart';
import '../../application/board_controller.dart';
import 'lint_dialog.dart';

/// Icon of a view's layout.
IconData layoutIcon(ViewLayoutDto layout) => switch (layout) {
  ViewLayoutDto.kanban => Icons.view_kanban_outlined,
  ViewLayoutDto.graph => Icons.account_tree_outlined,
  ViewLayoutDto.table => Icons.table_rows_outlined,
  ViewLayoutDto.list => Icons.list,
};

/// The navigation: app name, "New item", the saved views (those without a
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

  /// Opens an item chosen in the lint dialog.
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text(
              'kanban-ai',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tokens.text),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: FilledButton.icon(
              key: const ValueKey('new-item'),
              style: FilledButton.styleFrom(backgroundColor: tokens.accent, foregroundColor: tokens.onAccent),
              onPressed: controller.workflow == null ? null : onCreate,
              icon: const Icon(Icons.add, size: 18),
              // The label's colour is set explicitly: on the web it does not
              // follow foregroundColor here.
              label: Text('New item', style: TextStyle(color: tokens.onAccent)),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final (name, members) in sections)
                  if (name == null) ...[
                    const _SectionHeader(title: 'Views'),
                    for (final view in members) _ViewRow(controller: controller, view: view, onNavigate: onNavigate),
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
                      for (final view in members) _ViewRow(controller: controller, view: view, onNavigate: onNavigate),
                  ],
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title, this.collapsed = false, this.onToggle});

  final String title;
  final bool collapsed;

  /// Null for the heading of views without a section, which cannot fold.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final toggle = onToggle;
    return InkWell(
      borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 6, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: tokens.muted),
              ),
            ),
            if (toggle != null)
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: tokens.muted),
          ],
        ),
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
                if (count != null) Text('$count', style: TextStyle(fontSize: 12, color: tokens.muted)),
                _ViewMenu(controller: controller, view: view),
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
    builder: (context, menu, _) => IconButton(
      key: ValueKey('view-menu-${view.id}'),
      tooltip: 'View options',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      iconSize: 16,
      color: BoardTokens.of(context).muted,
      icon: const Icon(Icons.more_vert),
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
        TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('Remove from section')),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(_name.text.trim()), child: const Text('Move')),
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
                    if (view.count != null) ...[
                      const SizedBox(width: 6),
                      Text('${view.count}', style: TextStyle(fontSize: 12, color: tokens.muted)),
                    ],
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
