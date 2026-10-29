import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/copyable_id.dart';
import '../../../shared/item_style.dart';

/// Compact summary of an item for boards and lists.
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.item,
    this.workflow,
    this.onTap,
    this.showStatus = false,
    this.selected = false,
    this.footer,
  });

  final ItemDto item;
  final WorkflowDto? workflow;
  final VoidCallback? onTap;

  /// Shows the status too, for layouts that do not group by it.
  final bool showStatus;

  /// The item is open in the detail panel.
  final bool selected;

  /// Extra row at the bottom, e.g. the fold toggle of a parent.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      key: ValueKey('card-${item.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: selected ? scheme.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected
              ? scheme.primary
              : item.blocked
              ? scheme.error.withValues(alpha: 0.6)
              : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: ItemStyle.priority(item.priority, workflow), width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Tooltip(
                    message: item.type,
                    child: Icon(ItemStyle.type(item.type), size: 14, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 4),
                  CopyableId(item.id, style: muted),
                  if (item.type != 'task') ...[
                    const SizedBox(width: 6),
                    Text(item.type.toUpperCase(), style: muted?.copyWith(fontSize: 10, letterSpacing: 0.8)),
                  ],
                  const Spacer(),
                  Tag(item.priority, color: ItemStyle.priority(item.priority, workflow), filled: true),
                ],
              ),
              const SizedBox(height: 4),
              Text(item.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              if (_tags(context).isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 4, runSpacing: 4, children: _tags(context)),
              ],
              if (!item.checklist.isEmpty || !item.children.isEmpty) ...[
                const SizedBox(height: 6),
                _ProgressLine(item: item),
              ],
              ?footer,
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _tags(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (showStatus) Tag(item.status, color: ItemStyle.category(item.category, scheme)),
      if (item.milestone != null) Tag(item.milestone!, icon: Icons.outlined_flag, color: scheme.tertiary),
      for (final label in item.labels) Tag('#$label'),
      if (item.blocked) Tag('blocked by ${item.blockedBy.join(', ')}', icon: Icons.block, color: scheme.error),
      if (item.ready) Tag('ready', icon: Icons.play_arrow, color: Colors.green.shade700),
      if (item.claim case final claim?)
        Tag(
          claim.expired ? '${claim.agent} (expired)' : claim.agent,
          icon: Icons.smart_toy_outlined,
          color: claim.expired ? scheme.outline : Colors.amber.shade800,
        )
      else if (item.assignee != null && !item.isDone)
        Tag(item.assignee!, icon: Icons.person_outline),
    ];
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.item});

  final ItemDto item;

  @override
  Widget build(BuildContext context) {
    final progress = item.children.isEmpty ? item.checklist : item.children;
    final label = item.children.isEmpty ? 'checklist' : 'children';
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: progress.done / progress.total, minHeight: 4),
          ),
        ),
        const SizedBox(width: 8),
        Text('$label $progress', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
