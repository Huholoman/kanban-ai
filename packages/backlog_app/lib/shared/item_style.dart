import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

/// Colours and icons that encode item properties the same way everywhere.
abstract final class ItemStyle {
  /// Most urgent priority first in the workflow: red, orange, blue, grey, …
  static Color priority(String priority, WorkflowDto? workflow) {
    final rank = workflow?.priorities.indexOf(priority) ?? -1;
    return switch (rank) {
      0 => Colors.red.shade600,
      1 => Colors.orange.shade700,
      2 => Colors.blue.shade500,
      _ => Colors.blueGrey.shade400,
    };
  }

  static Color category(StatusCategoryDto? category, ColorScheme scheme) => switch (category) {
    StatusCategoryDto.open => scheme.outline,
    StatusCategoryDto.active => Colors.amber.shade700,
    StatusCategoryDto.done => Colors.green.shade600,
    null => scheme.error,
  };

  static IconData type(String type) => switch (type) {
    'epic' => Icons.flag_outlined,
    'story' => Icons.auto_stories_outlined,
    'bug' => Icons.bug_report_outlined,
    'decision' => Icons.gavel_outlined,
    'idea' => Icons.lightbulb_outline,
    _ => Icons.check_box_outlined,
  };
}

/// Small rounded label.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.icon, this.filled = false});

  final String text;
  final Color? color;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = color ?? theme.colorScheme.onSurfaceVariant;
    final foreground = filled ? Colors.white : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? base : base.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: foreground), const SizedBox(width: 3)],
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
