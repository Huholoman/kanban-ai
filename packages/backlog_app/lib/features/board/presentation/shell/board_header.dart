import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/app_scope.dart';
import '../../../../app/appearance_controller.dart';
import '../../../../shared/tokens.dart';
import '../../application/board_controller.dart';
import 'view_navigation.dart';

/// Top bar of the main area: the filter toolbar takes the space, compact
/// actions (columns, theme, reload) sit at the right end. With [compact]
/// (phone) the first row has the menu button, the view dropdown and the
/// actions, and the filter toolbar wraps below it.
class BoardHeader extends StatelessWidget {
  const BoardHeader({
    super.key,
    required this.controller,
    required this.filter,
    required this.onEditColumns,
    this.onMenu,
    this.compact = false,
  });

  final BoardController controller;

  /// The filter toolbar; null while there is no view to filter.
  final Widget? filter;
  final VoidCallback onEditColumns;

  /// Opens the navigation drawer; null when the navigation is always visible.
  final VoidCallback? onMenu;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final actions = _actions(context);
    final menu = onMenu;
    final Widget content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (menu != null) _HeaderButton(tooltip: 'Menu', icon: Icons.menu, onPressed: menu),
                  Expanded(child: _ViewPicker(controller: controller)),
                  ...actions,
                ],
              ),
              if (filter case final bar?) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: bar),
            ],
          )
        : Row(
            children: [
              if (menu != null) _HeaderButton(tooltip: 'Menu', icon: Icons.menu, onPressed: menu),
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

  List<Widget> _actions(BuildContext context) => [
    if (controller.loading)
      const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    if (controller.canEditColumns)
      _HeaderButton(
        key: const ValueKey('edit-columns'),
        tooltip: 'Columns of this view',
        icon: Icons.view_week_outlined,
        onPressed: onEditColumns,
      ),
    if (AppScope.of(context).appearance case final appearance?) _ModeButton(appearance: appearance),
    _HeaderButton(tooltip: 'Reload', icon: Icons.refresh, onPressed: () => unawaited(controller.refresh())),
  ];
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({super.key, required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 20,
    color: BoardTokens.of(context).muted,
    icon: Icon(icon),
    onPressed: onPressed,
  );
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
      return _HeaderButton(
        key: const ValueKey('theme-mode'),
        tooltip: 'Theme: $label (click to switch)',
        icon: icon,
        onPressed: appearance.cycleMode,
      );
    },
  );
}
