import 'package:flutter/material.dart';

import '../tokens.dart';

/// An accent pill holding a number (e.g. the active filters on their button).
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(9)),
      child: Text(
        '$count',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tokens.onAccent),
      ),
    );
  }
}

/// The muted number next to a name (navigation rows).
class CountText extends StatelessWidget {
  const CountText(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) =>
      Text('$count', style: TextStyle(fontSize: 12, color: BoardTokens.of(context).muted));
}
