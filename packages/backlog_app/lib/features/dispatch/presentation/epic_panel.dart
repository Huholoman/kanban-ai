import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../application/dispatch_controller.dart';
import 'dispatch_scope.dart';

/// *Implement epic*: loads whether one agent can implement [item] on one
/// branch, shows it and starts the agent when the reader agrees — a plain
/// start when nothing stands in the way, *Start anyway* with warnings, no
/// start when it cannot. The run is limited to one milestone (and the items
/// without one) or takes all of the epic; it starts with [milestone] (the
/// board's, else the epic's) when the epic has unfinished items in it and in
/// another milestone too.
Future<void> confirmEpicStart(
  BuildContext context,
  DispatchController dispatch,
  String item, {
  String? milestone,
}) async {
  final all = await dispatch.epic(item);
  if (!context.mounted) return;
  // The milestones with work left; with one (or none) the choice changes nothing.
  final milestones = [
    for (final entry in all?.progress ?? const <EpicProgressDto>[])
      if (!entry.finished) ?entry.milestone,
  ];
  final scoped = milestones.length > 1 && milestones.contains(milestone) ? milestone : null;
  final initial = scoped == null ? all : await dispatch.epic(item, milestone: scoped);
  if (!context.mounted) return;
  final chosen = await showDialog<_EpicChoice>(
    context: context,
    builder: (context) => _EpicDialog(
      dispatch: dispatch,
      item: item,
      milestones: milestones.length > 1 ? milestones : const [],
      milestone: scoped,
      epic: initial,
    ),
  );
  if (chosen != null) await dispatch.startEpic(item, milestone: chosen.milestone);
}

final class _EpicChoice {
  const _EpicChoice(this.milestone);

  final String? milestone;
}

class _EpicDialog extends StatefulWidget {
  const _EpicDialog({
    required this.dispatch,
    required this.item,
    required this.milestones,
    required this.milestone,
    required this.epic,
  });

  final DispatchController dispatch;
  final String item;

  /// The milestones of the epic's items to choose from; empty: no choice.
  final List<String> milestones;
  final String? milestone;
  final EpicDto? epic;

  @override
  State<_EpicDialog> createState() => _EpicDialogState();
}

class _EpicDialogState extends State<_EpicDialog> {
  late String? _milestone = widget.milestone;
  late EpicDto? _epic = widget.epic;
  bool _loading = false;

  /// Moves the parked item [id] to the pickable status (`todo`), so that
  /// the run takes it, and checks again.
  Future<void> _take(String id) async {
    final api = AppScope.of(context).api;
    setState(() => _loading = true);
    try {
      final workflow = await api.workflow();
      final status = workflow.statuses.where((s) => s.pickable).firstOrNull?.id ?? 'todo';
      await api.updateItem(id, ItemUpdateRequest(changes: [ItemUpdateRequest.set('status', status)]));
    } on BacklogApiException {
      // The check below shows the item as it is.
    }
    if (mounted) await _choose(_milestone);
  }

  Future<void> _choose(String? milestone) async {
    setState(() {
      _milestone = milestone;
      _loading = true;
    });
    final epic = await widget.dispatch.epic(widget.item, milestone: milestone);
    if (!mounted || milestone != _milestone) return;
    setState(() {
      _epic = epic;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final epic = _epic;
    return AlertDialog(
      key: const ValueKey('epic-dialog'),
      title: Text('Implement ${widget.item} as one epic?'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.milestones.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    key: const ValueKey('epic-scope'),
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final milestone in [...widget.milestones, null])
                        ChoiceChip(
                          key: ValueKey('epic-scope-${milestone ?? 'all'}'),
                          label: Text(milestone ?? 'All'),
                          selected: _milestone == milestone,
                          onSelected: (_) => unawaited(_choose(milestone)),
                        ),
                    ],
                  ),
                ),
              if (_loading)
                const LinearProgressIndicator()
              else if (epic == null)
                const Text('The server cannot say whether this epic can be implemented.')
              else
                EpicSummary(epic: epic, intro: true, onTake: (id) => unawaited(_take(id))),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (epic != null && !epic.isForbidden && !_loading)
          FilledButton(
            key: const ValueKey('epic-start'),
            onPressed: () => Navigator.of(context).pop(_EpicChoice(_milestone)),
            child: Text(epic.hasWarnings ? 'Start anyway' : 'Start'),
          ),
      ],
    );
  }
}

/// What the implementation of an epic looks like: the verdict with its
/// problems and warnings, the counts and the items in work order.
class EpicSummary extends StatelessWidget {
  const EpicSummary({super.key, required this.epic, this.intro = false, this.onTake});

  final EpicDto epic;

  /// Moves a parked item (`backlog`) to `todo`; without it parked items
  /// have no button.
  final ValueChanged<String>? onTake;

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
            'One agent works through '
            '${epic.milestone == null ? 'all items below' : 'the items of ${epic.milestone} (and those without a milestone)'}, '
            'one after another, in one session on the branch ${epic.branch}, hands each over to review and ends '
            'with one pull request for the epic. When the rest waits for something outside the epic, it asks on '
            'the epic and stops.',
          ),
        if (epic.skipped.isNotEmpty)
          line(
            '${epic.skipped.length} item(s) of other milestones stay as they are: ${epic.skipped.join(', ')}.',
            key: const ValueKey('epic-skipped'),
            color: tokens.muted,
          ),
        if (epic.parked.isNotEmpty)
          line(
            '${epic.parked.length} item(s) are not taken from the backlog: ${epic.parked.join(', ')}. Move what is '
            'next to todo, also while the agent works.',
            key: const ValueKey('epic-parked'),
            color: tokens.muted,
          ),
        if (onTake case final take? when epic.parked.isNotEmpty)
          Wrap(
            spacing: 4,
            children: [
              for (final id in epic.parked)
                TextButton(key: ValueKey('epic-take-$id'), onPressed: () => take(id), child: Text('Move $id to todo')),
            ],
          ),
        if (epic.progress.length > 1)
          line(
            [
              for (final entry in epic.progress)
                '${entry.milestone ?? 'no milestone'} ${entry.finished ? 'done' : '${entry.settled}/${entry.total}'}',
            ].join(' · '),
            key: const ValueKey('epic-milestones'),
            icon: Icons.flag_outlined,
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
          '${epic.count('in-progress')} in progress · ${epic.count('to-do')} to do'
          '${epic.parked.isEmpty ? '' : ' · ${epic.parked.length} in backlog'}',
          key: const ValueKey('epic-counts'),
          color: tokens.muted,
        ),
        for (final member in epic.members.where((m) => m.inScope))
          line(
            '${member.id}  ${member.title} (${member.status})'
            '${member.id == epic.next ? ' · next' : ''}'
            '${member.after.isEmpty ? '' : ' · after ${member.after.join(', ')}'}'
            '${member.waits.isEmpty ? '' : ' · waits for ${member.waits.join(', ')}'}'
            '${member.parked ? ' · not taken' : ''}',
            key: ValueKey('epic-member-${member.id}'),
            icon: switch (member.state) {
              'done' => Icons.check_circle,
              'handed-over' => Icons.rate_review_outlined,
              'in-progress' => Icons.play_circle_outline,
              _ when member.parked => Icons.pause_circle_outline,
              _ => Icons.radio_button_unchecked,
            },
            color: member.waits.isNotEmpty
                ? tokens.warning
                : member.parked
                ? tokens.muted
                : null,
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
      dispatch.epic(widget.item.id, milestone: dispatch.epicMilestone(widget.item.id)).then((epic) {
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
            'Epic implemented by one agent on ${epic.branch}'
            '${epic.milestone == null ? '' : ', milestone ${epic.milestone}'}',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tokens.text),
          ),
          EpicSummary(epic: epic),
        ],
      ),
    );
  }
}
