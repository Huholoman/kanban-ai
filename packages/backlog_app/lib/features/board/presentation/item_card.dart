import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/copyable_id.dart';
import '../../../shared/item_style.dart';
import '../../../shared/pr_link.dart';
import '../../../shared/tokens.dart';

/// Compact summary of an item for boards and lists: id and priority, the
/// title and one meta line that tells the state (waits for you, ready,
/// blocked, waiting for overlapping work, claimed, claim expired, or just
/// labels); a card that waits for a person has a warning border.
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.item,
    this.workflow,
    this.onTap,
    this.onLongPress,
    this.showStatus = false,
    this.selected = false,
    this.footer,
    this.now,
  });

  final ItemDto item;
  final WorkflowDto? workflow;
  final VoidCallback? onTap;

  /// E.g. the phone's "Move to…" sheet, where dragging is not possible.
  final VoidCallback? onLongPress;

  /// Shows the status too, for layouts that do not group by it.
  final bool showStatus;

  /// The item is open in the detail panel.
  final bool selected;

  /// Extra row at the bottom, e.g. the fold toggle of a parent.
  final Widget? footer;

  /// The current time for claim countdowns; the clock when null.
  final DateTime? now;

  /// How long a claim lasts yet: `1h left`, `25 min left`.
  static String timeLeft(DateTime expiresAt, DateTime now) {
    final left = expiresAt.difference(now);
    if (left.inMinutes < 1) return '<1 min left';
    if (left.inMinutes < 60) return '${left.inMinutes} min left';
    final minutes = left.inMinutes % 60;
    return minutes == 0 || left.inHours >= 10 ? '${left.inHours}h left' : '${left.inHours}h $minutes min left';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    final expired = item.claim?.expired ?? false;
    final muted = theme.textTheme.bodySmall?.copyWith(color: tokens.muted, fontSize: 11);
    final borderColor = selected
        ? tokens.accent
        : item.needsHuman && !item.isDone
        ? tokens.warning
        : (expired ? tokens.borderStrong : tokens.border);
    final progress = item.children.isEmpty ? item.checklist : item.children;
    final meta = _meta(context, tokens);
    return Opacity(
      opacity: item.isDone ? 0.7 : 1,
      child: CustomPaint(
        key: ValueKey('card-${item.id}'),
        foregroundPainter: CardBorderPainter(color: borderColor, width: selected ? 2 : 1, dashed: expired && !selected),
        child: Material(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(BoardTokens.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (item.type != 'task') ...[
                        Tooltip(
                          message: item.type,
                          child: Icon(
                            ItemStyle.type(item.type),
                            size: 12,
                            color: ItemStyle.typeColor(item.type, workflow) ?? tokens.muted,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Flexible(child: CopyableId(item.id, style: muted)),
                      if (showStatus) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Tag(
                            item.status,
                            color: ItemStyle.status(item.status, item.category, workflow, theme.colorScheme),
                          ),
                        ),
                      ],
                      const Spacer(),
                      _priority(tokens, muted),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.35),
                  ),
                  if (meta != null) ...[const SizedBox(height: 6), meta],
                  if (!progress.isEmpty) ...[const SizedBox(height: 6), _ProgressLine(progress: progress)],
                  if (footer != null) ...[const SizedBox(height: 2), footer!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Muted, except the most urgent priority and configured colours.
  Widget _priority(BoardTokens tokens, TextStyle? muted) {
    final configured = ItemStyle.parse(workflow?.appearance.priorities[item.priority]);
    final urgent = workflow?.priorities.firstOrNull == item.priority;
    final color = configured ?? (urgent ? tokens.warning : tokens.muted);
    return Text(
      item.priority,
      style: muted?.copyWith(color: color, fontWeight: urgent || configured != null ? FontWeight.w600 : null),
    );
  }

  /// The single line under the title, by the state of the item.
  Widget? _meta(BuildContext context, BoardTokens tokens) {
    final base = Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11, height: 1.3) ?? const TextStyle();
    final claim = item.claim;
    final parts = <Widget>[];
    if (item.isDone) {
      // Nothing to report on finished work except what it was about.
    } else if (item.needsHuman) {
      parts.add(
        Tooltip(
          message: 'An agent asked a question in the discussion',
          child: Text(
            '? Waits for you',
            key: ValueKey('needs-human-${item.id}'),
            style: base.copyWith(color: tokens.warning, fontWeight: FontWeight.w600),
          ),
        ),
      );
    } else if (item.blocked) {
      parts.add(Text('Blocked by ${item.blockedBy.join(', ')}', style: base.copyWith(color: tokens.warning)));
    } else if (item.conflicting) {
      parts.add(
        Tooltip(
          message: 'Touches the same files as work in progress',
          child: Text('Waits for ${item.conflictsWith.join(', ')}', style: base.copyWith(color: tokens.warning)),
        ),
      );
    } else if (claim != null && claim.expired) {
      parts.add(Text('Claim expired · ${claim.agent}', style: base.copyWith(color: tokens.faint)));
    } else if (claim != null) {
      final left = timeLeft(claim.expiresAt, now ?? DateTime.now());
      parts.add(Text('◉ ${claim.agent} · $left', style: base.copyWith(color: tokens.accent)));
    } else if (item.ready) {
      parts.add(
        Text(
          '● Ready',
          style: base.copyWith(color: tokens.success, fontWeight: FontWeight.w600),
        ),
      );
    }
    if (parts.isEmpty) {
      for (final label in item.labels) {
        parts.add(Text(label, style: base.copyWith(color: ItemStyle.label(label, workflow) ?? tokens.muted)));
      }
      if (item.milestone != null) parts.add(Text(item.milestone!, style: base));
      if (item.assignee != null && !item.isDone) parts.add(Text('@${item.assignee}', style: base));
    }
    if (item.pr case final pr?) {
      parts.add(PrLink(pr));
      if (item.branch != null) parts.add(Text(item.branch!, style: base));
    }
    if (parts.isEmpty) return null;
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, part) in parts.indexed) ...[if (i > 0) Text('·', style: base), part],
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.progress});

  final Progress progress;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.done / progress.total,
              minHeight: 3,
              color: tokens.accent,
              backgroundColor: tokens.border,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${progress.done} of ${progress.total} done',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tokens.muted),
        ),
      ],
    );
  }
}

/// Border of a card, drawn inside its bounds; dashed for expired claims.
class CardBorderPainter extends CustomPainter {
  const CardBorderPainter({required this.color, required this.width, this.dashed = false});

  final Color color;
  final double width;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final rect = (Offset.zero & size).deflate(width / 2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(BoardTokens.radius));
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 7) {
        canvas.drawPath(metric.extractPath(at, at + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(CardBorderPainter old) => old.color != color || old.width != width || old.dashed != dashed;
}
