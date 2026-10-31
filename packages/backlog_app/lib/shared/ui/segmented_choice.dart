import 'package:flutter/material.dart';

import '../tokens.dart';

/// One segment of a [SegmentedChoice].
@immutable
class ChoiceSegment<T> {
  const ChoiceSegment({required this.value, required this.label, this.tooltip, this.key});

  final T value;
  final String label;

  /// Shown on hover.
  final String? tooltip;

  /// Put on the tappable area (for tests).
  final Key? key;
}

/// A bordered group of toggle segments; a pressed one has the accent-soft
/// background and semibold accent text. Any number can be pressed at once.
/// When the space is too narrow for all segments, the group scrolls sideways.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({super.key, required this.segments, required this.selected, required this.onToggle});

  final List<ChoiceSegment<T>> segments;

  /// The pressed values.
  final Set<T> selected;

  /// A segment was tapped; the caller flips it in its state.
  final ValueChanged<T> onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Container(
      height: BoardTokens.controlHeight,
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderStrong),
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      ),
      clipBehavior: Clip.antiAlias,
      // Scrolls sideways when narrower than its segments (phones).
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (position, segment) in segments.indexed) ...[
              if (position > 0) VerticalDivider(width: 1, color: tokens.borderStrong),
              _Segment(
                label: segment.label,
                tooltip: segment.tooltip,
                itemKey: segment.key,
                pressed: selected.contains(segment.value),
                onTap: () => onToggle(segment.value),
                tokens: tokens,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.tooltip,
    required this.itemKey,
    required this.pressed,
    required this.onTap,
    required this.tokens,
  });

  final String label;
  final String? tooltip;
  final Key? itemKey;
  final bool pressed;
  final VoidCallback onTap;
  final BoardTokens tokens;

  @override
  Widget build(BuildContext context) {
    final body = Material(
      color: pressed ? tokens.accentSoft : tokens.surface,
      child: InkWell(
        key: itemKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: pressed ? FontWeight.w600 : FontWeight.w400,
                color: pressed ? tokens.accent : tokens.text,
              ),
            ),
          ),
        ),
      ),
    );
    final message = tooltip;
    return message == null
        ? body
        : Tooltip(message: message, waitDuration: const Duration(milliseconds: 500), child: body);
  }
}
