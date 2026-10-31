import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Colours and icons that encode item properties the same way everywhere.
/// Colours set in `appearance` of backlog.yaml win over the built-in ones.
abstract final class ItemStyle {
  /// `#rrggbb` as a colour; null for anything else.
  static Color? parse(String? hex) {
    if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
  }

  /// Most urgent priority first in the workflow: red, orange, blue, grey, …
  static Color priority(String priority, WorkflowDto? workflow) {
    if (parse(workflow?.appearance.priorities[priority]) case final configured?) return configured;
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

  /// The configured colour of [status], else the colour of its category.
  static Color status(String? status, StatusCategoryDto? category, WorkflowDto? workflow, ColorScheme scheme) =>
      parse(workflow?.appearance.statuses[status]) ?? ItemStyle.category(category, scheme);

  /// Configured colour of an item type; null keeps the neutral one.
  static Color? typeColor(String type, WorkflowDto? workflow) => parse(workflow?.appearance.types[type]);

  /// Configured colour of a label; null keeps the neutral one.
  static Color? label(String label, WorkflowDto? workflow) => parse(workflow?.appearance.labels[label]);

  /// Accent of a board column or list group, by what the view groups by.
  static Color group(String? field, String key, WorkflowDto? workflow, ColorScheme scheme) => switch (field) {
    'status' => status(key, workflow?.categoryOf(key), workflow, scheme),
    'priority' => priority(key, workflow),
    'type' => typeColor(key, workflow) ?? scheme.outline,
    'labels' => label(key, workflow) ?? scheme.outline,
    _ => scheme.outline,
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
    final tokens = BoardTokens.of(context);
    final configured = color;
    // Configured colours are picked for light pages; lift them on dark ones.
    final base = configured == null
        ? tokens.muted
        : theme.brightness == Brightness.dark && !filled
        ? Color.lerp(configured, Colors.white, 0.35)!
        : configured;
    final foreground = filled ? Colors.white : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: filled ? base : (configured == null ? tokens.chip : base.withValues(alpha: 0.10)),
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: foreground), const SizedBox(width: 3)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
