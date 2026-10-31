import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../application/dispatch_controller.dart';
import 'dispatch_scope.dart';

/// *Implement epic*: loads whether one agent can implement [item] on one
/// branch, shows it and starts the agent when the reader agrees — a plain
/// start when nothing stands in the way, *Start anyway* with warnings, no
/// start when it cannot.
Future<void> confirmEpicStart(BuildContext context, DispatchController dispatch, String item) async {
  final epic = await dispatch.epic(item);
  if (!context.mounted) return;
  final start = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('epic-dialog'),
      title: Text('Implement $item as one epic?'),
      content: SizedBox(
        width: 480,
        child: epic == null
            ? const Text('The server cannot say whether this epic can be implemented.')
            : SingleChildScrollView(child: EpicSummary(epic: epic, intro: true)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        if (epic != null && !epic.isForbidden)
          FilledButton(
            key: const ValueKey('epic-start'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(epic.hasWarnings ? 'Start anyway' : 'Start'),
          ),
      ],
    ),
  );
  if (start == true) await dispatch.startEpic(item);
}

/// What the implementation of an epic looks like: the verdict with its
/// problems and warnings, the counts and the items in work order.
class EpicSummary extends StatelessWidget {
  const EpicSummary({super.key, required this.epic, this.intro = false});

  final EpicDto epic;

  /// Before the start (the dialog): explain what starting does and give the
  /// verdict with its problems; otherwise only the warnings and progress.
  final bool intro;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    Widget line(String text, {Color? color, IconData? icon, Key? key}) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[Icon(icon, size: 16, color: color ?? tokens.muted), const SizedBox(width: 6)],
          Expanded(
            child: Text(
              text,
              key: key,
              style: small?.copyWith(color: color ?? tokens.text),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (intro)
          line(
            'One agent works through all items below, one after another, in one session on the branch '
            '${epic.branch}, hands each over to review and ends with one pull request for the epic. When the rest '
            'waits for something outside the epic, it asks on the epic and stops.',
          ),
        if (intro)
          line(
            switch (epic.verdict) {
              'ok' => 'Nothing stands in the way.',
              'warning' => 'It can start, but the agent will probably stop and ask:',
              _ => 'It cannot start:',
            },
            key: const ValueKey('epic-verdict'),
            icon: switch (epic.verdict) {
              'ok' => Icons.check_circle_outline,
              'warning' => Icons.warning_amber,
              _ => Icons.block,
            },
            color: switch (epic.verdict) {
              'ok' => tokens.success,
              'warning' => tokens.warning,
              _ => tokens.danger,
            },
          ),
        if (intro)
          for (final problem in epic.problems) line('✗ $problem', color: tokens.danger),
        for (final warning in epic.warnings) line('! $warning', color: tokens.warning),
        const SizedBox(height: 8),
        line(
          '${epic.count('done')} done · ${epic.count('handed-over')} handed over · '
          '${epic.count('in-progress')} in progress · ${epic.count('to-do')} to do',
          key: const ValueKey('epic-counts'),
          color: tokens.muted,
        ),
        for (final member in epic.members)
          line(
            '${member.id}  ${member.title} (${member.status})'
            '${member.id == epic.next ? ' · next' : ''}'
            '${member.after.isEmpty ? '' : ' · after ${member.after.join(', ')}'}'
            '${member.waits.isEmpty ? '' : ' · waits for ${member.waits.join(', ')}'}',
            key: ValueKey('epic-member-${member.id}'),
            icon: switch (member.state) {
              'done' => Icons.check_circle,
              'handed-over' => Icons.rate_review_outlined,
              'in-progress' => Icons.play_circle_outline,
              _ => Icons.radio_button_unchecked,
            },
            color: member.waits.isNotEmpty ? tokens.warning : null,
          ),
      ],
    );
  }
}

/// How far one agent's implementation of the epic [item] is, in its detail:
/// shown while the dispatcher knows it as an epic run; reloaded with the
/// dispatcher's plan.
class EpicProgress extends StatefulWidget {
  const EpicProgress({super.key, required this.item});

  final ItemDto item;

  @override
  State<EpicProgress> createState() => _EpicProgressState();
}

class _EpicProgressState extends State<EpicProgress> {
  DispatchController? _dispatch;
  EpicDto? _epic;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == _dispatch) return;
    _dispatch?.removeListener(_reload);
    _dispatch = dispatch?..addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _dispatch?.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    final dispatch = _dispatch;
    if (dispatch == null || !dispatch.isEpic(widget.item.id) || _loading) return;
    _loading = true;
    unawaited(
      dispatch.epic(widget.item.id).then((epic) {
        _loading = false;
        if (mounted) setState(() => _epic = epic);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final epic = _epic;
    if (epic == null || !(_dispatch?.isEpic(widget.item.id) ?? false)) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    return Container(
      key: const ValueKey('epic-progress'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.well,
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Epic implemented by one agent on ${epic.branch}',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tokens.text),
          ),
          EpicSummary(epic: epic),
        ],
      ),
    );
  }
}
