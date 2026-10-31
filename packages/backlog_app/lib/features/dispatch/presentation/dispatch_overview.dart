import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import 'dispatch_scope.dart';

/// The dispatcher in the navigation: mode and load, each worktree with what
/// runs there (or why it is unavailable), the proposed next starts with a
/// *Start* button, the held items and the waiting ones with the reason.
/// Empty without a dispatcher.
class DispatchOverview extends StatelessWidget {
  const DispatchOverview({super.key, required this.onOpenItem});

  final void Function(String id) onOpenItem;

  /// Waiting items listed with their reason; the rest are counted.
  static const _waitingRows = 3;

  @override
  Widget build(BuildContext context) {
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == null || !dispatch.configured) return const SizedBox.shrink();
    final plan = dispatch.plan;
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      key: const ValueKey('dispatch-overview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          'Agents · ${plan.mode} · ${plan.running}/${plan.maxAgents}'
          '${plan.maxWorktrees == null ? '' : ' · ${plan.worktrees.where((w) => !w.isNew).length}/${plan.maxWorktrees} worktrees'}',
        ),
        for (final worktree in plan.worktrees) _WorktreeRow(worktree: worktree, onOpenItem: onOpenItem),
        for (final assignment in plan.assignments)
          _Row(
            key: ValueKey('proposal-${assignment.item}'),
            icon: Icons.play_circle_outline,
            color: tokens.accent,
            text:
                '${assignment.item} → ${assignment.worktree}'
                '${assignment.newWorktree ? ' (new)' : ''}${assignment.resume == null ? '' : ' ↻'}',
            tooltip:
                '${plan.isManual ? 'Proposed' : 'Starting'}: ${assignment.title}'
                '${assignment.resume == null ? '' : ' (continues its last session)'}'
                '${assignment.newWorktree ? ' (creates worktree ${assignment.worktree})' : ''}',
            onTap: () => onOpenItem(assignment.item),
            trailing: plan.isManual
                ? IconActionButton(
                    key: ValueKey('start-${assignment.item}'),
                    tooltip: 'Start an agent',
                    icon: Icons.play_arrow,
                    size: 18,
                    box: 28,
                    onPressed: dispatch.pending.contains(assignment.item)
                        ? null
                        : () => unawaited(dispatch.startAgent(assignment.item)),
                  )
                : null,
          ),
        for (final held in plan.held)
          _Row(
            key: ValueKey('held-${held.item}'),
            icon: Icons.pause_circle_outline,
            color: tokens.warning,
            text: '${held.item} held',
            tooltip: '${held.title}: ${held.reason}',
            onTap: () => onOpenItem(held.item),
          ),
        for (final waiting in plan.waitingReasons.take(_waitingRows))
          _Row(
            key: ValueKey('waiting-${waiting.item}'),
            icon: Icons.hourglass_empty,
            color: tokens.muted,
            text: '${waiting.item} waits: ${waiting.reason}',
            tooltip: '${waiting.title}: waits for an agent (${waiting.reason})',
            onTap: () => onOpenItem(waiting.item),
          ),
        if (plan.waiting.length > _waitingRows || plan.waiting.length > plan.waitingReasons.length)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
            child: Text(
              '${plan.waiting.length - plan.waitingReasons.take(_waitingRows).length} more waiting',
              style: small,
            ),
          ),
      ],
    );
  }
}

class _WorktreeRow extends StatelessWidget {
  const _WorktreeRow({required this.worktree, required this.onOpenItem});

  final DispatchWorktreeDto worktree;
  final void Function(String id) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final run = worktree.run;
    final item = run?.item ?? worktree.claims.firstOrNull;
    final (icon, color, state) = switch (worktree) {
      _ when run != null => (Icons.smart_toy, tokens.success, run.item),
      _ when worktree.busy => (Icons.lock_outline, tokens.muted, item ?? 'busy'),
      _ when worktree.unavailable != null => (Icons.block, tokens.warning, 'unavailable'),
      _ when worktree.isNew => (Icons.add_circle_outline, tokens.faint, 'new'),
      _ => (Icons.check_circle_outline, tokens.faint, 'free'),
    };
    return _Row(
      key: ValueKey('worktree-${worktree.name}'),
      icon: icon,
      color: color,
      text: '${worktree.name} · $state',
      tooltip:
          worktree.unavailable ??
          (run != null
              ? '${run.agent} on ${run.branch ?? run.item}'
              : worktree.isNew
              ? 'Created at ${worktree.path} when its agent starts'
              : '${worktree.path}${worktree.created ? ' (created by the dispatcher)' : ''}'),
      onTap: item == null ? null : () => onOpenItem(item),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    required this.tooltip,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.text),
                ),
              ),
              ?trailing,
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
