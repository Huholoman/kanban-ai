import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/dispatch_controller.dart';
import 'dispatch_scope.dart';

/// The icon of an action by what it runs: an agent, a command, a built-in.
IconData actionIcon(ActionDto action) => switch (action.kind) {
  _ when action.review => Icons.rate_review_outlined,
  'prompt' => Icons.smart_toy_outlined,
  'command' => Icons.terminal,
  _ => Icons.bolt,
};

/// What pressing [action] does, for tooltips.
String actionHint(ActionDto action) => switch (action.kind) {
  _ when action.review =>
    'Starts ${action.agent ?? 'the agent'} in a new session to review the item\'s branch; it changes nothing and '
        'records its verdict in the discussion',
  'prompt' =>
    'Starts ${action.agent ?? 'the agent'} on this item'
        '${action.fresh ? ' in a new session' : ', continuing its session when it can'}; the status stays',
  'command' => 'Runs a command in the item\'s worktree; the result goes into the discussion',
  _ => 'Runs the built-in action; the result goes into the discussion',
};

/// The buttons of the item's [actions] (`dispatcher.actions` offered in its
/// status), for the detail; disabled while something runs for the item.
List<Widget> actionButtons(BuildContext context, ItemDto item, List<ActionDto> actions, {bool enabled = true}) {
  final dispatch = DispatchScope.maybeOf(context);
  if (dispatch == null || !dispatch.configured || actions.isEmpty) return const [];
  final can = enabled && dispatch.canRunAction(item.id);
  return [
    for (final action in actions)
      Tooltip(
        message: actionHint(action),
        child: SecondaryButton(
          key: ValueKey('action-${action.name}'),
          label: action.name,
          icon: actionIcon(action),
          onPressed: can ? () => unawaited(dispatch.runAction(item.id, action.name)) : null,
        ),
      ),
  ];
}

/// The actions of a card's status behind a small "⋯" menu (only when the
/// status offers some); an hourglass while something runs for the item.
class CardActionsMenu extends StatelessWidget {
  const CardActionsMenu({super.key, required this.item, required this.workflow});

  final ItemDto item;
  final WorkflowDto? workflow;

  @override
  Widget build(BuildContext context) {
    final dispatch = DispatchScope.maybeOf(context);
    final actions = workflow?.actionsIn(item.status) ?? const <ActionDto>[];
    if (dispatch == null || !dispatch.configured || actions.isEmpty) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    final run = dispatch.runFor(item.id);
    final busy = !dispatch.canRunAction(item.id);
    return SizedBox(
      width: 22,
      height: 18,
      child: PopupMenuButton<String>(
        key: ValueKey('card-actions-${item.id}'),
        tooltip: run == null ? 'Actions' : 'Running: ${run.action ?? 'agent'}',
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(
          run == null ? Icons.more_horiz : Icons.hourglass_top,
          color: run == null ? tokens.muted : tokens.accent,
        ),
        onSelected: (name) => unawaited(_run(dispatch, name)),
        itemBuilder: (context) => [
          for (final action in actions)
            PopupMenuItem<String>(
              key: ValueKey('card-action-${action.name}'),
              value: action.name,
              enabled: !busy,
              child: Row(
                children: [
                  Icon(actionIcon(action), size: 16),
                  const SizedBox(width: 8),
                  Flexible(child: Text(action.name)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _run(DispatchController dispatch, String name) => dispatch.runAction(item.id, name);
}
