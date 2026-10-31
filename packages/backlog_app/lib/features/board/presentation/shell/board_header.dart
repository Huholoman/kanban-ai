import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/app_scope.dart';
import '../../../../app/appearance_controller.dart';
import '../../../../shared/tokens.dart';
import '../../../../shared/ui/ui.dart';
import '../../application/board_controller.dart';
import 'view_navigation.dart';

/// Top bar of the main area: the filter toolbar takes the space, compact
/// actions (columns, theme, reload) sit at the right end. With [compact]
/// (phone) the row has the menu button, the view dropdown, a filter toggle
/// and the actions; the filter toolbar slides down below it while
/// [filterOpen], so the board keeps the screen otherwise.
class BoardHeader extends StatelessWidget {
  const BoardHeader({
    super.key,
    required this.controller,
    required this.filter,
    required this.onEditColumns,
    this.onMenu,
    this.compact = false,
    this.filterOpen = false,
    this.onToggleFilter,
  });

  final BoardController controller;

  /// The filter toolbar; null while there is no view to filter.
  final Widget? filter;
  final VoidCallback onEditColumns;

  /// Opens the navigation drawer; null when the navigation is always visible.
  final VoidCallback? onMenu;
  final bool compact;

  /// Whether the compact header shows the filter toolbar.
  final bool filterOpen;

  /// Shows or hides the filter toolbar of the compact header.
  final VoidCallback? onToggleFilter;

  /// Below this header width the Group by menu shrinks to an icon.
  static const roomyWidth = 1000.0;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) => _build(context, roomy: constraints.maxWidth >= roomyWidth));

  Widget _build(BuildContext context, {required bool roomy}) {
    final tokens = BoardTokens.of(context);
    final actions = _actions(context, roomy: roomy);
    final menu = onMenu;
    final Widget content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (menu != null) IconActionButton(tooltip: 'Menu', icon: Icons.menu, onPressed: menu),
                  Expanded(child: _ViewPicker(controller: controller)),
                  if (filter != null && onToggleFilter != null)
                    _FilterToggle(open: filterOpen, active: !controller.filter.isEmpty, onPressed: onToggleFilter!),
                  ...actions,
                ],
              ),
              ClipRect(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: switch (filter) {
                    final bar? when filterOpen || onToggleFilter == null => Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: bar,
                    ),
                    _ => const SizedBox(width: double.infinity),
                  },
                ),
              ),
            ],
          )
        : Row(
            children: [
              if (menu != null) IconActionButton(tooltip: 'Menu', icon: Icons.menu, onPressed: menu),
              Expanded(child: filter ?? const SizedBox.shrink()),
              ...actions,
            ],
          );
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: content,
    );
  }

  List<Widget> _actions(BuildContext context, {required bool roomy}) => [
    if (controller.loading)
      const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    if (controller.result != null && !compact) _GroupByMenu(controller: controller, iconOnly: !roomy),
    if (controller.canEditColumns)
      IconActionButton(
        key: const ValueKey('edit-columns'),
        tooltip: 'Columns of this view',
        icon: Icons.view_week_outlined,
        onPressed: onEditColumns,
      ),
    if (AppScope.of(context).appearance case final appearance?) _ModeButton(appearance: appearance),
    IconActionButton(tooltip: 'Reload', icon: Icons.refresh, onPressed: () => unawaited(controller.refresh())),
  ];
}

/// "Group: status ▾" — regroups the current view for the session; the first
/// entry goes back to the view's own grouping.
class _GroupByMenu extends StatelessWidget {
  const _GroupByMenu({required this.controller, this.iconOnly = false});

  final BoardController controller;

  /// Just an icon with the grouping in its tooltip, for narrow headers.
  final bool iconOnly;

  static String _label(String? field) => switch (field) {
    null || '' => 'none',
    final field => field,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final current = controller.result?.groupBy;
    final override = controller.groupByOverride;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('group-by-default'),
          onPressed: override == null ? null : () => unawaited(controller.setGroupBy(null)),
          child: const Text("The view's own"),
        ),
        for (final field in BoardController.groupableFields)
          MenuItemButton(
            key: ValueKey('group-by-$field'),
            trailingIcon: field == current ? Icon(Icons.check, size: 16, color: tokens.accent) : null,
            onPressed: () => unawaited(controller.setGroupBy(field)),
            child: Text(field),
          ),
        MenuItemButton(
          key: const ValueKey('group-by-none'),
          trailingIcon: current == null ? Icon(Icons.check, size: 16, color: tokens.accent) : null,
          onPressed: () => unawaited(controller.setGroupBy('')),
          child: const Text('none'),
        ),
      ],
      builder: (context, menu, _) {
        final label = 'Group: ${_label(current)}${override == null ? '' : ' *'}';
        void toggle() => menu.isOpen ? menu.close() : menu.open();
        if (iconOnly) {
          return IconActionButton(
            key: const ValueKey('group-by'),
            tooltip: label,
            icon: Icons.segment,
            onPressed: toggle,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SecondaryButton(key: const ValueKey('group-by'), label: label, icon: Icons.segment, onPressed: toggle),
        );
      },
    );
  }
}

/// Shows or hides the filter toolbar of the phone header; a dot marks an
/// active filter while the toolbar is hidden.
class _FilterToggle extends StatelessWidget {
  const _FilterToggle({required this.open, required this.active, required this.onPressed});

  final bool open;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return IconButton(
      key: const ValueKey('filter-toggle'),
      tooltip: open ? 'Hide filters' : 'Search and filter',
      iconSize: 20,
      isSelected: open,
      color: open ? tokens.accent : null,
      icon: Badge(
        key: const ValueKey('filter-toggle-dot'),
        isLabelVisible: active && !open,
        backgroundColor: tokens.accent,
        smallSize: 8,
        child: const Icon(Icons.manage_search),
      ),
      onPressed: onPressed,
    );
  }
}

/// View dropdown of the phone header.
class _ViewPicker extends StatelessWidget {
  const _ViewPicker({required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.views.isEmpty) return const Text('Backlog');
    final tokens = BoardTokens.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('view-picker'),
        isExpanded: true,
        value: controller.selectedViewId,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: tokens.text),
        items: [
          for (final view in controller.views)
            DropdownMenuItem(
              value: view.id,
              child: Row(
                children: [
                  Icon(layoutIcon(view.layout), size: 18, color: tokens.muted),
                  const SizedBox(width: 8),
                  Flexible(child: Text(view.name, overflow: TextOverflow.ellipsis)),
                ],
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
      return IconActionButton(
        key: const ValueKey('theme-mode'),
        tooltip: 'Theme: $label (click to switch)',
        icon: icon,
        onPressed: appearance.cycleMode,
      );
    },
  );
}
