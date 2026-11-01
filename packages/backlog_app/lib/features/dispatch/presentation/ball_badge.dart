import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../application/ball.dart';
import '../application/next_step.dart';
import 'dispatch_scope.dart';

/// Who has the ball of an item, the same small tag on cards, in the agent
/// box of the detail and on the Dashboard: *Agent works*, *AI review*,
/// *Waits for you* (red after a run with problems) or *Queued*; the tooltip
/// says why and, when it is a person's turn, the next step ([next]).
/// Nothing when nobody has it.
class BallBadge extends StatelessWidget {
  const BallBadge(this.ball, {super.key, required this.item, this.next});

  /// The badge of [item] by the plan of the enclosing [DispatchScope];
  /// [workflow] tells which actions are AI reviews.
  static Widget of(ItemDto item, WorkflowDto? workflow, {Key? key}) => Builder(
    key: key,
    builder: (context) {
      final dispatch = DispatchScope.maybeOf(context);
      final ball = dispatch == null ? null : Ball.of(item, dispatch.plan, workflow);
      return ball == null
          ? const SizedBox.shrink()
          : BallBadge(ball, item: item.id, next: NextStep.of(item, dispatch!.plan, workflow));
    },
  );

  final Ball ball;

  /// The item's id, for the key.
  final String item;

  /// What the person has to do next, for the tooltip.
  final NextStep? next;

  static String label(BallHolder holder) => switch (holder) {
    BallHolder.agent => 'Agent works',
    BallHolder.aiReview => 'AI review',
    BallHolder.you => 'Waits for you',
    BallHolder.queue => 'Queued',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final (icon, color) = switch (ball.holder) {
      BallHolder.agent => (Icons.smart_toy, tokens.success),
      BallHolder.aiReview => (Icons.rate_review_outlined, tokens.accent),
      BallHolder.you when ball.problems => (Icons.error_outline, tokens.danger),
      BallHolder.you => (Icons.person_outline, tokens.warning),
      BallHolder.queue => (Icons.schedule, tokens.muted),
    };
    return Tooltip(
      message: next == null ? ball.reason : '${ball.reason}\nNext: ${next!.text}',
      child: Tag(label(ball.holder), key: ValueKey('ball-${ball.holder.name}-$item'), icon: icon, color: color),
    );
  }
}
