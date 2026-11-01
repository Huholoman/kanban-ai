import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/pr_link.dart';
import '../../../shared/review_badge.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../../dispatch/application/ball.dart';
import '../../dispatch/application/next_step.dart';
import '../../dispatch/presentation/agent_panel.dart';
import '../../dispatch/presentation/ball_badge.dart';
import '../../dispatch/presentation/next_step_line.dart';
import '../application/dashboard_controller.dart';
import '../application/project_digest.dart';

/// Opens an item of the project.
typedef OpenItem = void Function(String item);

/// The dashboard's sections of one project as lists of widgets, for one
/// column or two.
final class DashboardSections {
  const DashboardSections({required this.digest, required this.controller, required this.onOpen});

  final ProjectDigest digest;
  final DashboardController controller;
  final OpenItem onOpen;

  /// Key of a row: `dashboard:<name>`.
  static ValueKey<String> _key(String name) => ValueKey('dashboard:$name');

  /// What [pick] takes from the digest, each with the digest.
  Iterable<(ProjectDigest, T)> _each<T>(List<T> Function(ProjectDigest digest) pick) =>
      pick(digest).map((entry) => (digest, entry));

  /// Questions, approvals, failures and clean-up.
  List<Widget> needsYou() {
    final questions = _each((d) => d.waitingForAnswer).toList();
    final approvals = _each((d) => d.toApprove).toList();
    final held = _each((d) => d.held).toList();
    final problems = _each((d) => d.problems).toList();
    final expired = _each((d) => d.expiredClaims).toList();
    final worktrees = _each((d) => d.unavailableWorktrees).toList();
    final lint = [if (digest.lint.isNotEmpty) digest];
    final clean = expired.isEmpty && worktrees.isEmpty && lint.isEmpty;
    return [
      _Heading(
        'Needs you',
        count: questions.length + approvals.length + problems.length + held.length,
        key: const ValueKey('needs-you'),
      ),
      if (questions.isEmpty && approvals.isEmpty && problems.isEmpty && held.isEmpty && clean)
        const _Empty('Nothing waits for you.'),
      if (questions.isNotEmpty) ...[
        _Subheading('Questions', count: questions.length),
        for (final (digest, item) in questions)
          _QuestionCard(
            key: _key('question-${item.id}'),
            digest: digest,
            item: item,
            controller: controller,
            onOpen: onOpen,
          ),
      ],
      if (approvals.isNotEmpty) ...[
        _Subheading('To approve', count: approvals.length),
        for (final (digest, item) in approvals)
          _ItemRow(
            key: _key('approve-${item.id}'),
            digest: digest,
            id: item.id,
            title: item.title,
            onOpen: onOpen,
            icon: Icons.fact_check_outlined,
            next: _next(digest, item.id, withActions: false),
            details: [
              ReviewBadge(item),
              if (item.pr case final pr?) PrLink(pr),
              if (item.branch case final branch?) Tag(branch, icon: Icons.alt_route),
            ],
            actions: _actions(digest, item),
          ),
      ],
      if (problems.isNotEmpty) ...[
        _Subheading('Problems', count: problems.length),
        for (final (digest, entry) in problems)
          if (_next(digest, entry.item) case final next)
            _ItemRow(
              key: _key('problem-${entry.item}'),
              digest: digest,
              id: entry.item,
              title: entry.title,
              onOpen: onOpen,
              icon: Icons.error_outline,
              iconColor: (tokens) => tokens.danger,
              next: next,
              // A next step that quotes the first problem leaves the rest here.
              note: next?.step.quotesProblem ?? false
                  ? (entry.problems.length > 1 ? entry.problems.skip(1).join('\n') : null)
                  : entry.problems.join('\n'),
            ),
      ],
      if (held.isNotEmpty) ...[
        _Subheading('Stopped', count: held.length),
        for (final (digest, entry) in held)
          if (_next(digest, entry.item) case final next)
            _ItemRow(
              key: _key('held-${entry.item}'),
              digest: digest,
              id: entry.item,
              title: entry.title,
              onOpen: onOpen,
              icon: Icons.pause_circle_outline,
              iconColor: (tokens) => tokens.warning,
              next: next,
              // The held step says the reason itself.
              note: next?.step.kind == NextStepKind.held ? null : entry.reason,
            ),
      ],
      if (!clean) ...[
        const _Subheading('Clean-up'),
        for (final (digest, item) in expired)
          _ItemRow(
            key: _key('expired-${item.id}'),
            digest: digest,
            id: item.id,
            title: item.title,
            onOpen: onOpen,
            icon: Icons.lock_clock_outlined,
            note: 'Claim of ${item.claim!.agent} expired',
          ),
        for (final (_, worktree) in worktrees)
          _Line(
            key: _key('unavailable-${worktree.name}'),
            icon: Icons.block,
            text: '${worktree.name}: ${worktree.unavailable}',
          ),
        for (final digest in lint)
          _Line(
            key: _key('lint'),
            icon: digest.lintErrors > 0 ? Icons.error_outline : Icons.warning_amber,
            text: 'Lint: ${_count(digest.lintErrors, 'error')}, ${_count(digest.lintWarnings, 'warning')}',
          ),
      ],
    ];
  }

  /// Running agents and the dispatcher's queue.
  List<Widget> running() {
    final runs = _each((d) => d.runs).toList();
    final dispatched = [if (digest.plan.configured) digest];
    final proposals = _each((d) => d.plan.assignments).toList();
    final waiting = _each((d) => d.plan.waitingReasons).toList();
    final queued = _each((d) => d.plan.queue).toList();
    final conflicting = _each((d) => d.conflicting).toList();
    return [
      _Heading('Running', count: runs.length, key: const ValueKey('running')),
      if (runs.isEmpty) const _Empty('No agent runs.'),
      for (final (digest, run) in runs)
        _ItemRow(
          key: _key('run-${run.item}'),
          digest: digest,
          id: run.item,
          title: digest.item(run.item)?.title ?? '',
          onOpen: onOpen,
          icon: run.kind == 'agent' ? Icons.smart_toy : Icons.terminal,
          iconColor: (tokens) => tokens.success,
          note:
              '${run.action == null ? run.agent : 'Action "${run.action}"'} in ${run.worktree} '
              'since ${sinceText(run.startedAt)}${run.branch == null ? '' : ' · ${run.branch}'}'
              '${switch (digest.workedOnBy(run)) {
                [] => '',
                final items => ' · on ${items.map((i) => i.id).join(', ')}',
              }}',
          actions: [
            if (run.kind != 'builtin')
              _ActionButton(
                key: ValueKey('stop-${run.item}'),
                label: 'Stop',
                icon: Icons.stop,
                onPressed: controller.isPending(digest, run.item)
                    ? null
                    : (context) => unawaited(_confirmStop(context, digest, run.item)),
              ),
          ],
        ),
      if (dispatched.isNotEmpty || conflicting.isNotEmpty) ...[
        const _Subheading('Queue'),
        for (final digest in dispatched)
          _Line(
            key: _key('capacity'),
            icon: Icons.speed,
            text:
                'Agents ${digest.plan.running}/${digest.plan.maxAgents} · ${digest.plan.mode}'
                '${digest.plan.waiting.isEmpty ? '' : ' · ${digest.plan.waiting.length} waiting'}'
                '${digest.plan.queue.isEmpty ? '' : ' · ${digest.plan.queue.length} queued'}',
          ),
        for (final (digest, proposal) in proposals)
          _ItemRow(
            key: _key('proposal-${proposal.item}'),
            digest: digest,
            id: proposal.item,
            title: proposal.title,
            onOpen: onOpen,
            icon: Icons.play_circle_outline,
            iconColor: (tokens) => tokens.accent,
            note:
                '${digest.plan.isManual ? 'Next' : 'Starting'} in ${proposal.worktree}'
                '${proposal.newWorktree ? ' (new)' : ''}${proposal.resume == null ? '' : ' · continues its session'}',
            actions: [
              if (digest.plan.isManual)
                _ActionButton(
                  key: ValueKey('start-${proposal.item}'),
                  label: 'Start',
                  icon: Icons.play_arrow,
                  onPressed: controller.isPending(digest, proposal.item)
                      ? null
                      : (_) => unawaited(controller.startAgent(digest, proposal.item)),
                ),
            ],
          ),
        for (final (digest, start) in queued)
          _ItemRow(
            key: _key('queued-${start.item}'),
            digest: digest,
            id: start.item,
            title: start.title,
            onOpen: onOpen,
            icon: Icons.schedule,
            iconColor: (tokens) => tokens.accent,
            note: 'In the queue (${start.position}): ${start.what} waits for ${start.reason}',
            actions: [
              _ActionButton(
                key: ValueKey('cancel-queued-${start.item}'),
                label: 'Cancel',
                icon: Icons.close,
                onPressed: controller.isPending(digest, start.item)
                    ? null
                    : (_) => unawaited(controller.cancelQueued(digest, start.item)),
              ),
            ],
          ),
        for (final (digest, entry) in waiting)
          _ItemRow(
            key: _key('waiting-${entry.item}'),
            digest: digest,
            id: entry.item,
            title: entry.title,
            onOpen: onOpen,
            icon: Icons.hourglass_empty,
            note: 'Waits: ${entry.reason}',
          ),
        for (final (digest, item) in conflicting)
          _ItemRow(
            key: _key('conflicting-${item.id}'),
            digest: digest,
            id: item.id,
            title: item.title,
            onOpen: onOpen,
            icon: Icons.call_split,
            note: 'Waits for ${item.conflictsWith.join(', ')} (touches the same files)',
          ),
      ],
    ];
  }

  /// Milestone progress and urgent work.
  List<Widget> overview() {
    final milestones = _each((d) => d.milestones).toList();
    final urgent = _each((d) => d.urgent).toList();
    if (milestones.isEmpty && urgent.isEmpty) return const [];
    return [
      const _Heading('Overview', key: ValueKey('overview')),
      for (final (_, progress) in milestones)
        _MilestoneRow(key: _key('milestone-${progress.milestone.id}'), progress: progress),
      if (urgent.isNotEmpty) ...[
        _Subheading('Urgent', count: urgent.length),
        for (final (digest, item) in urgent)
          _ItemRow(
            key: _key('urgent-${item.id}'),
            digest: digest,
            id: item.id,
            title: item.title,
            onOpen: onOpen,
            icon: ItemStyle.type(item.type),
            iconColor: (tokens) => tokens.warning,
            details: [
              Tag(item.priority),
              Tag(item.status),
              if (item.milestone case final milestone?) Tag(milestone, icon: Icons.flag_outlined),
            ],
          ),
      ],
    ];
  }

  /// The next step of [id] with its buttons; without [withActions] the
  /// row offers the status's actions by itself.
  NextStepLine? _next(ProjectDigest digest, String id, {bool withActions = true}) {
    final item = digest.item(id);
    final step = item == null ? null : NextStep.of(item, digest.plan, digest.workflow);
    if (step == null) return null;
    final busy = controller.isPending(digest, id) || digest.plan.runFor(id) != null;
    return NextStepLine(
      step,
      item: id,
      busy: busy,
      onAction: withActions ? (name) => unawaited(controller.runAction(digest, id, name)) : null,
      onStart: () => unawaited(controller.startAgent(digest, id)),
      onOpen: onOpen,
    );
  }

  /// The actions the item's status offers (Merge, fix the review, …).
  List<_ActionButton> _actions(ProjectDigest digest, ItemDto item) {
    final busy = controller.isPending(digest, item.id) || digest.plan.runFor(item.id) != null;
    return [
      for (final action in digest.workflow?.actionsIn(item.status) ?? const <ActionDto>[])
        _ActionButton(
          key: ValueKey('action-${item.id}-${action.name}'),
          label: action.name,
          icon: action.review
              ? Icons.rate_review_outlined
              : switch (action.kind) {
                  'prompt' => Icons.smart_toy_outlined,
                  'command' => Icons.terminal,
                  _ => Icons.bolt,
                },
          onPressed: busy ? null : (_) => unawaited(controller.runAction(digest, item.id, action.name)),
        ),
    ];
  }

  Future<void> _confirmStop(BuildContext context, ProjectDigest digest, String item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop the agent of $item?'),
        content: const Text('The process is terminated; the item goes back to the queue, held.'),
        actions: [
          LinkButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          PrimaryButton(label: 'Stop', onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (confirmed ?? false) await controller.stopAgent(digest, item);
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {super.key, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (count case final count? when count > 0) ...[const SizedBox(width: 8), CountBadge(count)],
      ],
    ),
  );
}

class _Subheading extends StatelessWidget {
  const _Subheading(this.title, {this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) =>
      SectionLabel(count == null ? title : '$title · $count', padding: const EdgeInsets.fromLTRB(16, 12, 16, 4));
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(text, style: TextStyle(color: BoardTokens.of(context).muted)),
  );
}

/// A button of a row; it gets the row's context (for dialogs).
class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.label, required this.icon, required this.onPressed});

  final String label;
  final IconData icon;
  final void Function(BuildContext context)? onPressed;

  @override
  Widget build(BuildContext context) => SecondaryButton(
    label: label,
    icon: icon,
    onPressed: switch (onPressed) {
      final pressed? => () => pressed(context),
      null => null,
    },
  );
}

/// One item: icon, id and title (a tap opens it), the next step, a note
/// line, tags (who has the ball first) and buttons.
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.digest,
    required this.id,
    required this.title,
    required this.onOpen,
    required this.icon,
    this.iconColor,
    this.note,
    this.next,
    this.details = const [],
    this.actions = const [],
  });

  final ProjectDigest digest;
  final String id;
  final String title;
  final OpenItem onOpen;
  final IconData icon;
  final Color Function(BoardTokens tokens)? iconColor;
  final String? note;

  /// What the person has to do next, under the title.
  final Widget? next;
  final List<Widget> details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.muted);
    final ball = switch (digest.item(id)) {
      final item? => Ball.of(item, digest.plan, digest.workflow),
      null => null,
    };
    final tags = [if (ball != null) BallBadge(ball, item: id), ...details];
    return InkWell(
      onTap: () => onOpen(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: iconColor?.call(tokens) ?? tokens.muted),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$id  ',
                          style: TextStyle(color: tokens.muted, fontSize: 12),
                        ),
                        TextSpan(
                          text: title,
                          style: TextStyle(color: tokens.text),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (next case final next?) Padding(padding: const EdgeInsets.only(top: 2), child: next),
                  if (note case final note?) Text(note, style: small),
                  if (tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(spacing: 6, runSpacing: 4, children: tags),
                    ),
                  if (actions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(spacing: 6, runSpacing: 6, children: actions),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line that is not about one item (a worktree, lint, capacity).
class _Line extends StatelessWidget {
  const _Line({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: tokens.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: tokens.text)),
          ),
        ],
      ),
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  const _MilestoneRow({super.key, required this.progress});

  final MilestoneProgress progress;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final milestone = progress.milestone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${milestone.title ?? milestone.id}${milestone.due == null ? '' : ' · due ${milestone.due}'}',
                  style: TextStyle(color: tokens.text),
                ),
              ),
              Text('${progress.done}/${progress.total} done', style: TextStyle(color: tokens.muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.done / progress.total,
              minHeight: 4,
              color: tokens.success,
              backgroundColor: tokens.well,
            ),
          ),
        ],
      ),
    );
  }
}

/// An open question with the field to answer it.
class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    super.key,
    required this.digest,
    required this.item,
    required this.controller,
    required this.onOpen,
  });

  final ProjectDigest digest;
  final ItemDto item;
  final DashboardController controller;
  final OpenItem onOpen;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _answer.text.trim();
    if (text.isEmpty) return;
    if (await widget.controller.answer(widget.digest, widget.item.id, text)) _answer.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final item = widget.item;
    final question = widget.digest.questions[item.id];
    final pending = widget.controller.isPending(widget.digest, item.id);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.warning),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ItemRow(
            digest: widget.digest,
            id: item.id,
            title: item.title,
            onOpen: widget.onOpen,
            icon: Icons.help_outline,
            iconColor: (tokens) => tokens.warning,
            note: question == null ? 'Waits for you' : '${question.author} asked · ${sinceText(question.at)}',
          ),
          if (question != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 0, 16, 4),
              child: SelectableText(question.text.trim(), style: TextStyle(color: tokens.text)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(44, 4, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('answer-${item.id}'),
                    controller: _answer,
                    minLines: 1,
                    maxLines: 6,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: question == null ? 'Answer…' : 'Answer ${question.author}…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PrimaryButton(
                  key: ValueKey('send-${item.id}'),
                  label: 'Send',
                  icon: Icons.send,
                  onPressed: pending ? null : () => unawaited(_send()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
