import 'package:backlog_api/backlog_api.dart';

/// Who has the ball of an item: who has to act next.
enum BallHolder {
  /// The item's agent, or an action that changes code, runs.
  agent,

  /// An AI review (an action with `review: true`) runs.
  aiReview,

  /// A person: a question, a problem of the last run, a hold, or work that
  /// waits in the review status with nothing running.
  you,

  /// A start or an `on_enter` action waits in the dispatcher's queue.
  queue,
}

/// Who has the ball of an item and why ([reason], a sentence for the
/// tooltip); [problems] when a person is needed because the last run went
/// wrong.
final class Ball {
  const Ball(this.holder, this.reason, {this.problems = false});

  final BallHolder holder;
  final String reason;
  final bool problems;

  /// The status whose items wait for a person when nothing runs for them.
  static const reviewStatus = 'review';

  /// Who has the ball of [item] by the dispatcher's [plan]; [workflow]
  /// tells which actions are AI reviews. Null for finished items, without a
  /// dispatcher and when nobody has it (open work nobody started).
  static Ball? of(ItemDto item, DispatchDto plan, WorkflowDto? workflow) {
    if (!plan.configured || item.isDone) return null;
    final id = item.id;
    final claim = item.claim;
    final run = plan.runFor(id) ?? (claim == null || claim.expired ? null : plan.runWorkingOn(id, claim.agent));
    if (run != null) return _running(id, run, workflow);
    if (item.needsHuman) return const Ball(BallHolder.you, 'An agent asked a question in the discussion');
    if (plan.problemsOf(id) case final problems when problems.isNotEmpty) {
      return Ball(BallHolder.you, 'The last run needs you:\n${problems.join('\n')}', problems: true);
    }
    if (plan.heldReason(id) case final held?) return Ball(BallHolder.you, 'Held: $held');
    if (plan.queuedFor(id) case final start?) {
      return Ball(BallHolder.queue, 'Queued: ${start.what} waits for ${start.reason} · position ${start.position}');
    }
    if (plan.pendingFor(id) case [final pending, ...]) {
      return Ball(
        BallHolder.queue,
        'Queued: the action "${pending.action}" (entered ${pending.status}) waits until nothing else runs for the item',
      );
    }
    if (item.status == reviewStatus) return const Ball(BallHolder.you, 'Waits for your review');
    return null;
  }

  static Ball _running(String id, AgentRunDto run, WorkflowDto? workflow) {
    final where = ' in ${run.worktree}';
    if (run.item != id) return Ball(BallHolder.agent, 'The agent of ${run.item} works on it (${run.agent}$where)');
    final action = run.action;
    if (action == null) return Ball(BallHolder.agent, 'Agent ${run.agent} works$where');
    final review = workflow?.actions.any((a) => a.name == action && a.review) ?? false;
    return review
        ? Ball(BallHolder.aiReview, 'AI review "$action" runs$where')
        : Ball(BallHolder.agent, 'Action "$action" runs$where');
  }
}
