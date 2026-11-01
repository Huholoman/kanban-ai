import 'package:flutter/material.dart';

import '../../../shared/pr_link.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/next_step.dart';

/// The next step of an item ([NextStep]) as one line, *Next: …*, with the
/// buttons that do it: *Open PR*, the offered actions ([onAction]), *Start
/// agent* ([onStart]) and *Open X-1* for blockers ([onOpen]). Buttons
/// without a callback are left out; [busy] disables them.
class NextStepLine extends StatelessWidget {
  const NextStepLine(
    this.step, {
    super.key,
    required this.item,
    this.onAction,
    this.onStart,
    this.onOpen,
    this.busy = false,
  });

  final NextStep step;

  /// The item's id, for the keys.
  final String item;
  final ValueChanged<String>? onAction;
  final VoidCallback? onStart;
  final ValueChanged<String>? onOpen;
  final bool busy;

  static IconData icon(NextStepKind kind) => switch (kind) {
    NextStepKind.answer => Icons.help_outline,
    NextStepKind.fix => Icons.build_outlined,
    NextStepKind.held => Icons.pause_circle_outline,
    NextStepKind.review => Icons.fact_check_outlined,
    NextStepKind.resolve => Icons.rate_review_outlined,
    NextStepKind.start => Icons.play_circle_outline,
    NextStepKind.unblock => Icons.link,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final buttons = <Widget>[
      if (step.pr case final pr?)
        SecondaryButton(
          key: ValueKey('next-pr-$item'),
          label: 'Open ${PrLink.label(pr)}',
          icon: Icons.open_in_new,
          onPressed: PrLink.opener(pr),
        ),
      if (onAction case final run?)
        for (final action in step.actions)
          SecondaryButton(
            key: ValueKey('next-action-$item-$action'),
            label: action,
            icon: Icons.bolt,
            onPressed: busy ? null : () => run(action),
          ),
      if (step.start && onStart != null)
        SecondaryButton(
          key: ValueKey('next-start-$item'),
          label: 'Start agent',
          icon: Icons.play_arrow,
          onPressed: busy ? null : onStart,
        ),
      if (onOpen case final open?)
        for (final other in step.open)
          LinkButton(key: ValueKey('next-open-$item-$other'), label: 'Open $other', onPressed: () => open(other)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon(step.kind), size: 16, color: tokens.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Next: ${step.text}',
                key: ValueKey('next-step-$item'),
                style: small?.copyWith(color: tokens.text, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        if (buttons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Wrap(spacing: 6, runSpacing: 6, children: buttons),
          ),
      ],
    );
  }
}
