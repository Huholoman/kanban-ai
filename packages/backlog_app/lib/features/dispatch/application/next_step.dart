import 'package:backlog_api/backlog_api.dart';

import '../../../shared/pr_link.dart';
import 'ball.dart';

/// What the next step of an item asks of a person.
enum NextStepKind {
  /// An agent asked a question: answer it.
  answer,

  /// The last run ended with problems (a failed merge or push, denied tool
  /// calls, …): fix what they say, then retry.
  fix,

  /// The dispatcher holds the item back: start its agent again.
  held,

  /// The work waits in the review status: look through it and move it on.
  review,

  /// The AI review asks for changes: resolve its findings or answer.
  resolve,

  /// Ready and nothing runs (manual mode): start an agent.
  start,

  /// Dependencies are not done yet.
  unblock,
}

/// The concrete next step of an item, one sentence ([text]) and what does
/// it: the workflow [actions] to offer by name, the pull request to open
/// ([pr]), *Start agent* ([start]) and the items to open ([open]). Derived
/// in one place for the badge's tooltip, the agent box of the detail and the
/// Dashboard.
final class NextStep {
  const NextStep(this.kind, this.text, {this.actions = const [], this.pr, this.start = false, this.open = const []});

  final NextStepKind kind;
  final String text;
  final List<String> actions;
  final String? pr;
  final bool start;
  final List<String> open;

  /// The next step of [item] by the dispatcher's [plan] and the [workflow]'s
  /// actions; [question] is the open question of an agent, when known. Null
  /// without a dispatcher, for finished items and while the ball is not with
  /// a person (something runs or waits in the queue for the item).
  static NextStep? of(ItemDto item, DispatchDto plan, WorkflowDto? workflow, {CommentDto? question}) {
    if (!plan.configured || item.isDone) return null;
    final id = item.id;
    final ball = Ball.of(item, plan, workflow);
    if (ball != null && ball.holder != BallHolder.you) return null;
    final offered = workflow?.actionsIn(item.status) ?? const <ActionDto>[];
    if (item.needsHuman) {
      final asked = question?.text.trim().split('\n').first.trim();
      return NextStep(
        NextStepKind.answer,
        asked == null || asked.isEmpty
            ? 'Answer the agent\'s question in the discussion'
            : 'Answer ${question!.author}: $asked',
      );
    }
    final problems = plan.problemsOf(id);
    if (problems.isNotEmpty) {
      final retry = offered.where((a) => !a.review && a.kind != 'prompt').map((a) => a.name).toList();
      final more = problems.length > 1 ? ' (and ${problems.length - 1} more)' : '';
      return NextStep(
        NextStepKind.fix,
        '${problems.first.trim()}$more – fix it, then '
        '${retry.isEmpty ? 'start the agent again' : 'run ${_names(retry)} again'}',
        actions: retry,
        start: retry.isEmpty && item.ready,
      );
    }
    if (plan.heldReason(id) case final held?) {
      return NextStep(NextStepKind.held, 'Held: $held – start the agent again when it can go on', start: item.ready);
    }
    if (item.status == Ball.reviewStatus) return _review(item, offered);
    if (ball != null) return null;
    if (item.blocked && item.blockedBy.isNotEmpty) {
      return NextStep(
        NextStepKind.unblock,
        'Waits for ${item.blockedBy.join(', ')} (not done yet)',
        open: item.blockedBy,
      );
    }
    if (item.ready && item.claim == null && plan.isManual && plan.runFor(id) == null) {
      return item.children.total > 0
          ? const NextStep(NextStepKind.start, 'Ready and nothing runs – Implement epic')
          : const NextStep(NextStepKind.start, 'Ready and nothing runs – Start agent', start: true);
    }
    return null;
  }

  static NextStep _review(ItemDto item, List<ActionDto> offered) {
    final reviews = [
      for (final a in offered)
        if (a.review) a.name,
    ];
    final moves = [
      for (final a in offered)
        if (!a.review && a.kind != 'prompt') a.name,
    ];
    final fixes = [
      for (final a in offered)
        if (!a.review && a.kind == 'prompt') a.name,
    ];
    final pr = item.pr;
    final work = pr != null
        ? PrLink.label(pr)
        : item.branch == null
        ? 'the work'
        : 'the branch ${item.branch}';
    final move = moves.isEmpty ? 'move it on' : 'run ${_names(moves)}';
    return switch (item.review) {
      'changes' => NextStep(
        NextStepKind.resolve,
        'AI review has ${item.reviewFindings == 1 ? '1 finding' : '${item.reviewFindings} findings'} – '
        '${fixes.isEmpty ? 'resolve them' : 'resolve them with ${_names(fixes)}'} or answer in the discussion',
        actions: fixes,
        pr: pr,
      ),
      'stale' => NextStep(
        NextStepKind.review,
        'AI review is outdated (the branch has newer commits) – '
        '${reviews.isEmpty ? 'look through $work again' : 'run ${_names(reviews)} again'}, then $move',
        actions: [...reviews, ...moves],
        pr: pr,
      ),
      'ok' => NextStep(NextStepKind.review, 'AI review ✓ – look through $work and $move', actions: moves, pr: pr),
      _ => NextStep(NextStepKind.review, 'Look through $work and $move', actions: [...reviews, ...moves], pr: pr),
    };
  }

  /// `"Merge"`, `"Merge" or "Deploy"`.
  static String _names(List<String> names) => names.map((n) => '"$n"').join(' or ');
}
