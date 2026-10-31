import 'package:flutter/material.dart';

import '../tokens.dart';
import 'buttons.dart';

/// One action of an [ActionBar]: a button inline, an entry of its "More"
/// menu when the bar has too many.
class BarAction {
  const BarAction({
    required this.label,
    required this.onPressed,
    this.key,
    this.icon,
    this.tooltip,
    this.primary = false,
  });

  final String label;

  /// Null disables it.
  final VoidCallback? onPressed;
  final Key? key;
  final IconData? icon;
  final String? tooltip;

  /// A [PrimaryButton] inline instead of a [SecondaryButton].
  final bool primary;
}

/// A wrapping row of action buttons. With more than [maxInline] actions the
/// first `maxInline - 1` stay buttons and the rest go behind a "More…" menu,
/// so a status with many actions does not fill the screen.
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.actions, this.maxInline = 4, this.alignment = WrapAlignment.start});

  final List<BarAction> actions;
  final int maxInline;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final overflow = actions.length > maxInline;
    final inline = overflow ? actions.take(maxInline - 1) : actions;
    final rest = overflow ? actions.skip(maxInline - 1).toList() : const <BarAction>[];
    return Wrap(
      alignment: alignment,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final action in inline) _button(action),
        if (rest.isNotEmpty) _MoreMenu(actions: rest),
      ],
    );
  }

  static Widget _button(BarAction action) {
    final button = action.primary
        ? PrimaryButton(key: action.key, label: action.label, icon: action.icon, onPressed: action.onPressed)
        : SecondaryButton(key: action.key, label: action.label, icon: action.icon, onPressed: action.onPressed);
    return action.tooltip == null ? button : Tooltip(message: action.tooltip, child: button);
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.actions});

  final List<BarAction> actions;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return MenuAnchor(
      menuChildren: [
        for (final action in actions)
          _withTooltip(
            action.tooltip,
            MenuItemButton(
              key: action.key,
              leadingIcon: action.icon == null ? null : Icon(action.icon, size: 16),
              onPressed: action.onPressed,
              child: Text(action.label, style: TextStyle(color: action.onPressed == null ? tokens.faint : tokens.text)),
            ),
          ),
      ],
      builder: (context, menu, _) => SecondaryButton(
        key: const ValueKey('action-bar-more'),
        label: 'More…',
        icon: Icons.more_horiz,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }

  static Widget _withTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);
}
