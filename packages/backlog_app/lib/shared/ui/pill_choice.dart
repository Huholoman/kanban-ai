import 'package:flutter/material.dart';

import '../tokens.dart';

/// A row of rounded radio pills, one per option; exactly one is selected and
/// a tap on another reports it through [onSelect]. A [selected] value that is
/// not among [options] is appended so it stays visible.
class PillChoice extends StatelessWidget {
  const PillChoice({
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

  /// False ignores taps.
  final bool enabled;

  /// Colour of the selected pill; the accent when null.
  final Color Function(String value)? colorOf;

  /// Key of a pill's material (for tests).
  final Key Function(String value)? keyOf;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final all = [...options, if (!options.contains(selected)) selected];
    return Wrap(spacing: 6, runSpacing: 6, children: [for (final option in all) _pill(tokens, option)]);
  }

  Widget _pill(BoardTokens tokens, String option) {
    final isSelected = option == selected;
    final accent = colorOf?.call(option) ?? tokens.accent;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: isSelected,
      child: Material(
        key: keyOf?.call(option),
        color: isSelected ? (colorOf == null ? tokens.accentSoft : accent.withValues(alpha: 0.10)) : tokens.surface,
        shape: StadiumBorder(side: BorderSide(color: isSelected ? accent : tokens.borderStrong)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: !enabled || isSelected ? null : () => onSelect(option),
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              option,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? accent : tokens.text,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
