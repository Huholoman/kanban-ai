import 'package:flutter/material.dart';

import '../tokens.dart';

/// A small uppercase muted heading. With [onToggle] it is a button that
/// shows a chevron for [collapsed] / expanded.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.title, {
    super.key,
    this.collapsed = false,
    this.onToggle,
    this.padding = const EdgeInsets.fromLTRB(10, 12, 6, 4),
  });

  final String title;
  final bool collapsed;

  /// Null for a plain heading that cannot fold.
  final VoidCallback? onToggle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final toggle = onToggle;
    return InkWell(
      borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      onTap: toggle,
      child: Padding(
        padding: padding,
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
