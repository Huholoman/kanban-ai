import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import 'dispatch_scope.dart';

/// A card's small sign that the dispatcher needs a person for the item:
/// its last run ended with problems (red) or it is held (amber); the
/// tooltip says why. Nothing otherwise — a running agent shows in the
/// card's claim line.
class AgentStateBadge extends StatelessWidget {
  const AgentStateBadge({super.key, required this.item});

  final ItemDto item;

  @override
  Widget build(BuildContext context) {
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == null || !dispatch.configured || item.isDone || dispatch.runFor(item.id) != null) {
      return const SizedBox.shrink();
    }
    final tokens = BoardTokens.of(context);
    final problems = dispatch.plan.problemsOf(item.id);
    final held = dispatch.plan.heldReason(item.id);
    final (icon, color, message, name) = problems.isNotEmpty
        ? (Icons.error_outline, tokens.danger, 'The last run needs you:\n${problems.join('\n')}', 'problems')
        : held != null
        ? (Icons.pause_circle_outline, tokens.warning, 'Held: $held', 'held')
        : (null, null, null, null);
    if (icon == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: message,
        child: Icon(icon, key: ValueKey('agent-$name-${item.id}'), size: 14, color: color),
      ),
    );
  }
}
