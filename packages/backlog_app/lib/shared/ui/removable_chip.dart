import 'package:flutter/material.dart';

import '../tokens.dart';

/// A chip with a × button, for filters the user can drop. Read-only tags are
/// `Tag`.
class RemovableChip extends StatelessWidget {
  const RemovableChip({super.key, required this.text, required this.onRemove, this.removeKey});

  final String text;
  final VoidCallback onRemove;

  /// Key of the × button (for tests).
  final Key? removeKey;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(color: tokens.chip, borderRadius: BorderRadius.circular(BoardTokens.controlHeight)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(text, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            key: removeKey,
            tooltip: 'Remove',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            iconSize: 12,
            color: tokens.muted,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
