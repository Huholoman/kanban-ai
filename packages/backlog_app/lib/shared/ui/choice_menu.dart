import 'package:flutter/material.dart';

import '../tokens.dart';

/// One value out of a list, as a compact chip (coloured dot, the value, ▾)
/// that opens a menu of all options — for fields like status or priority
/// whose options would take a whole row as buttons. A [selected] value that
/// is not among [options] is still listed so it stays visible.
class ChoiceMenu extends StatelessWidget {
  const ChoiceMenu({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.enabled = true,
    this.colorOf,
    this.keyOf,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;

  /// False shows the value without opening the menu.
  final bool enabled;

  /// Colour of a value's dot; the accent when null.
  final Color Function(String value)? colorOf;

  /// Key of a menu entry (for tests).
  final Key Function(String value)? keyOf;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final values = [...options, if (!options.contains(selected)) selected];
    Widget dot(String value) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: colorOf?.call(value) ?? tokens.accent, shape: BoxShape.circle),
    );
    return MenuAnchor(
      menuChildren: [
        for (final value in values)
          MenuItemButton(
            key: keyOf?.call(value),
            leadingIcon: dot(value),
            trailingIcon: value == selected ? Icon(Icons.check, size: 16, color: tokens.accent) : null,
            onPressed: value == selected ? null : () => onSelect(value),
            child: Text(value, style: TextStyle(color: tokens.text)),
          ),
      ],
      builder: (context, menu, _) => Material(
        color: tokens.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          side: BorderSide(color: tokens.borderStrong),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          onTap: enabled ? () => menu.isOpen ? menu.close() : menu.open() : null,
          child: SizedBox(
            height: BoardTokens.controlHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dot(selected),
                  const SizedBox(width: 8),
                  Text(selected, style: TextStyle(color: enabled ? tokens.text : tokens.faint)),
                  Icon(Icons.arrow_drop_down, size: 20, color: enabled ? tokens.muted : tokens.faint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
