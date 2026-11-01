import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/agent_log_controller.dart';
import '../application/ball.dart';
import '../application/dispatch_controller.dart';
import '../application/next_step.dart';
import 'agent_log_view.dart';
import 'ball_badge.dart';
import 'dispatch_scope.dart';
import 'next_step_line.dart';

/// `14:05 (12 min)`: when [time] was, and how long ago.
String sinceText(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final minutes = (now ?? DateTime.now()).difference(time).inMinutes;
  String two(int value) => value.toString().padLeft(2, '0');
  final ago = minutes < 1
      ? 'just now'
      : minutes < 60
      ? '$minutes min'
      : '${minutes ~/ 60} h ${minutes % 60} min';
  return '${two(local.hour)}:${two(local.minute)} ($ago)';
}

/// The dispatcher's view of one item in its detail, its state at a glance:
/// the agent working on it (worktree, since when, branch, the last line of
/// its log, *Stop*), why the dispatcher holds it back or lets it wait, or
/// how its last run ended — fine, or with problems that need a person —
/// with the agent's final message; the log on demand. An item another
/// item's agent works on (an epic's agent going through its children) shows
/// that agent and its log, with a link to that item ([onOpen]). Its first
/// line starts with who has the ball ([BallBadge]), followed by the next
/// step when it is a person's turn ([NextStepLine]). Empty when none applies.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.item, this.workflow, this.onOpen, this.question});

  final ItemDto item;

  /// The agent's open question, quoted by the next step.
  final CommentDto? question;

  /// Tells which actions are AI reviews.
  final WorkflowDto? workflow;

  /// Opens another item (the one whose agent works on this one).
  final ValueChanged<String>? onOpen;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  AgentLogController? _log;

  /// Shown or hidden by the reader; by default shown while an agent runs.
  bool? _showLogChoice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _followLog();
  }

  @override
  void didUpdateWidget(AgentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _followLog();
  }

  /// The agent of another item that works on this one, if any.
  AgentRunDto? _workingOn(DispatchController dispatch) {
    final claim = widget.item.claim;
    return claim == null || claim.expired || widget.item.isDone
        ? null
        : dispatch.plan.runWorkingOn(widget.item.id, claim.agent);
  }

  /// Follows the log of the item's own agent, or of the agent of another
  /// item that works on it ([_workingOn]).
  void _followLog() {
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == null || !dispatch.configured) return;
    final target = _workingOn(dispatch)?.item ?? widget.item.id;
    if (_log?.item == target) return;
    _log?.dispose();
    _log = AgentLogController(AppScope.of(context).api, target)
      ..addListener(_logChanged)
      ..start();
  }

  void _logChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _log?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == null || !dispatch.configured) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final id = widget.item.id;
    final run = dispatch.runFor(id);
    final via = run == null ? _workingOn(dispatch) : null;
    final held = dispatch.plan.heldReason(id);
    final waiting = dispatch.plan.waitingReason(id);
    final queued = dispatch.pendingActionsFor(id);
    final reply = dispatch.plan.queuedReplyOf(id);
    final start = dispatch.queuedFor(id);
    final log = _log;
    final hasLog = log?.hasLog ?? false;
    final running = run != null || via != null || (log?.running ?? false);
    // The log of another item's agent says nothing about this item's own runs.
    final last = running || log?.item != id ? null : log?.last;
    final problems = running
        ? const <String>[]
        : (last?.problems.isNotEmpty ?? false)
        ? last!.problems
        : dispatch.plan.problemsOf(id);
    // A finished item needs nobody: the problems of its last run are history.
    final needsYou = problems.isNotEmpty && !widget.item.isDone;
    final problemsText = problems.length == 1 ? 'a problem' : 'problems';
    final ball = Ball.of(widget.item, dispatch.plan, widget.workflow);
    final next = NextStep.of(widget.item, dispatch.plan, widget.workflow, question: widget.question);
    if (ball == null &&
        next == null &&
        run == null &&
        via == null &&
        held == null &&
        waiting == null &&
        !hasLog &&
        queued.isEmpty &&
        start == null &&
        problems.isEmpty) {
      return const SizedBox.shrink();
    }
    final showLog = hasLog && (_showLogChoice ?? running);
    final (icon, color, text) = switch (run ?? via) {
      final run? when run == via => (
        Icons.smart_toy,
        tokens.success,
        'The agent of ${run.item} works on it: ${run.agent} in ${run.worktree} since ${sinceText(run.startedAt)}'
            '${run.branch == null ? '' : ' · ${run.branch}'}',
      ),
      final run? => (
        Icons.smart_toy,
        tokens.success,
        '${_running(run)} since ${sinceText(run.startedAt)}${run.branch == null ? '' : ' · ${run.branch}'}',
      ),
      _ when start != null => (Icons.schedule, tokens.accent, 'In the queue to start'),
      _ when held != null => (Icons.pause_circle_outline, tokens.warning, 'Held: $held'),
      _ when waiting != null => (Icons.hourglass_empty, tokens.warning, 'Waiting for an agent: $waiting'),
      _ when needsYou => (Icons.error_outline, tokens.danger, 'Needs you: the last run ended with $problemsText'),
      _ when last != null && problems.isNotEmpty => (
        Icons.history,
        tokens.muted,
        [
          'Last run ended${last.endedAt == null ? '' : ' ${sinceText(last.endedAt!)}'}',
          ?last.outcome,
          'with $problemsText',
        ].join(' · '),
      ),
      _ when last != null => (
        Icons.check_circle_outline,
        tokens.success,
        [
          'Done · last run ended${last.endedAt == null ? '' : ' ${sinceText(last.endedAt!)}'}',
          ?last.outcome,
        ].join(' · '),
      ),
      _ when !hasLog && ball != null => (
        Icons.info_outline,
        tokens.muted,
        ball.holder == BallHolder.queue ? 'In the queue' : ball.reason,
      ),
      _ => (Icons.smart_toy_outlined, tokens.muted, 'Agent · last run'),
    };
    final lastLine = run == null && via == null
        ? null
        : log?.lines.lastWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    return Container(
      key: const ValueKey('agent-panel'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.well,
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ball != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: BallBadge(ball, item: id),
                      ),
                    Text(
                      text,
                      key: ValueKey(run != null || via != null ? 'agent-running' : 'agent-held'),
                      style: small?.copyWith(color: tokens.text),
                    ),
                    if (lastLine case final line? when line.isNotEmpty && !showLog)
                      Text(
                        line.trim(),
                        key: const ValueKey('agent-last-line'),
                        style: small?.copyWith(color: tokens.muted, fontFamily: 'monospace', fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (via != null && widget.onOpen != null)
                LinkButton(
                  key: const ValueKey('agent-open-runner'),
                  label: 'Open ${via.item}',
                  onPressed: () => widget.onOpen!(via.item),
                ),
              if (hasLog)
                LinkButton(
                  key: const ValueKey('agent-log-toggle'),
                  label: showLog ? 'Hide log' : 'Log',
                  onPressed: () => setState(() => _showLogChoice = !showLog),
                ),
              if (run != null && run.kind != 'builtin')
                SecondaryButton(
                  key: const ValueKey('stop-agent'),
                  label: 'Stop',
                  icon: Icons.stop,
                  onPressed: dispatch.pending.contains(id)
                      ? null
                      : () => unawaited(_confirmStop(dispatch.stopAgent, run.action)),
                ),
            ],
          ),
          if (next != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NextStepLine(
                next,
                item: id,
                busy: !dispatch.canRunAction(id),
                onAction: (name) => unawaited(dispatch.runAction(id, name)),
                onStart: dispatch.canStart(widget.item) ? () => unawaited(dispatch.startAgent(id)) : null,
                onOpen: widget.onOpen,
              ),
            ),
          if (reply != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: tokens.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'A message waits: $reply',
                      key: const ValueKey('agent-reply-queued'),
                      style: small?.copyWith(color: tokens.accent),
                    ),
                  ),
                ],
              ),
            ),
          if (start != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: tokens.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Queued: ${start.what} waits for ${start.reason} · position ${start.position}',
                      key: const ValueKey('start-queued'),
                      style: small?.copyWith(color: tokens.accent),
                    ),
                  ),
                  LinkButton(
                    key: const ValueKey('cancel-queued'),
                    label: 'Cancel',
                    onPressed: dispatch.pending.contains(id) ? null : () => unawaited(dispatch.cancelQueued(id)),
                  ),
                ],
              ),
            ),
          for (final pending in queued)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: tokens.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Queued: the action "${pending.action}" (entered ${pending.status} at '
                      '${sinceText(pending.since)}); it starts once nothing else runs for the item',
                      key: ValueKey('action-queued-${pending.action}'),
                      style: small?.copyWith(color: tokens.muted),
                    ),
                  ),
                ],
              ),
            ),
          if (problems.isNotEmpty)
            Padding(
              key: const ValueKey('agent-problems'),
              padding: const EdgeInsets.only(left: 26, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final problem in problems)
                    Text('• $problem', style: small?.copyWith(color: needsYou ? tokens.danger : tokens.muted)),
                ],
              ),
            ),
          if (last?.result case final result?) ...[
            const SizedBox(height: 8),
            _FinalMessage(
              result,
              color: problems.isEmpty
                  ? tokens.success
                  : needsYou
                  ? tokens.danger
                  : tokens.muted,
            ),
          ],
          if (showLog && log != null) ...[const SizedBox(height: 8), AgentLogView(controller: log)],
        ],
      ),
    );
  }

  /// `Agent claude in wt-2`, `Action "AI review" · claude in wt-2`,
  /// `Action "Tests" (command) in wt-2`.
  static String _running(AgentRunDto run) => switch (run) {
    AgentRunDto(action: null, epic: true) => 'Agent ${run.agent} implements the epic in ${run.worktree}',
    AgentRunDto(action: null) => 'Agent ${run.agent} in ${run.worktree}',
    AgentRunDto(kind: 'agent') => 'Action "${run.action}" · ${run.agent} in ${run.worktree}',
    _ => 'Action "${run.action}" (${run.kind == 'builtin' ? 'built-in' : run.kind}) in ${run.worktree}',
  };

  Future<void> _confirmStop(Future<void> Function(String item) stop, String? action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action == null ? 'Stop the agent of ${widget.item.id}?' : 'Stop the action "$action"?'),
        content: Text(
          action == null
              ? 'Its process is terminated; the item goes back to the queue and is held. '
                    'Uncommitted changes stay in the worktree.'
              : 'Its process is terminated; the item keeps its status. Uncommitted changes stay in the worktree.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Stop')),
        ],
      ),
    );
    if (confirmed == true) await stop(widget.item.id);
  }
}

/// The agent's final message of its last run, selectable, with a stripe in
/// [color] (how the run went); long messages scroll.
class _FinalMessage extends StatelessWidget {
  const _FinalMessage(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      key: const ValueKey('agent-result'),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Last message of the agent', style: small?.copyWith(color: tokens.muted)),
            const SizedBox(height: 2),
            SelectableText(text, style: small?.copyWith(color: tokens.text, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
