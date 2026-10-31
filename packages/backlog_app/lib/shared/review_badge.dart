import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import 'item_style.dart';
import 'tokens.dart';

/// The AI review state of an item ([ItemDto.review]) as a small tag: `AI
/// review…` while one runs, `AI review ✓`, `AI review: 3 findings`, `AI
/// review outdated`; nothing without a review.
class ReviewBadge extends StatelessWidget {
  const ReviewBadge(this.item, {super.key});

  final ItemDto item;

  /// The label for [item], or null when it has no review.
  static String? label(ItemDto item) => switch (item.review) {
    'running' => 'AI review…',
    'ok' => 'AI review ✓',
    'changes' => switch (item.reviewFindings) {
      0 => 'AI review: changes',
      1 => 'AI review: 1 finding',
      final n => 'AI review: $n findings',
    },
    'stale' => 'AI review outdated',
    _ => null,
  };

  static String _tooltip(String review) => switch (review) {
    'running' => 'An AI review runs for this item (or waits to run)',
    'ok' => 'The latest review found nothing to change',
    'changes' => 'The latest review asks for changes; its findings are in the discussion',
    _ => 'The branch has commits the latest review did not see',
  };

  @override
  Widget build(BuildContext context) {
    final text = label(item);
    if (text == null) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    final (icon, color) = switch (item.review) {
      'running' => (Icons.rate_review_outlined, tokens.accent),
      'ok' => (Icons.verified_outlined, tokens.success),
      'changes' => (Icons.rule, tokens.warning),
      _ => (Icons.history, tokens.faint),
    };
    return Tooltip(
      message: _tooltip(item.review),
      child: Tag(text, key: ValueKey('review-${item.id}'), icon: icon, color: color),
    );
  }
}
