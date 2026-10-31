import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';

import 'backlog_command.dart';

/// `backlog action <id> [<name>]`: lists the actions an item offers, or asks
/// the server's dispatcher to run one. The CLI has no dispatcher of its
/// own: it writes a request into the backlog's `.locks/actions/`, which a
/// running `backlog-server` picks up and starts (or explains in the item's
/// discussion why it could not).
final class ActionCommand extends BacklogCommand {
  ActionCommand(super.context) {
    argParser.addOption('as', help: 'Who asks (default: \$BACKLOG_AGENT, else \$USER).', valueHelp: 'name');
  }

  @override
  String get name => 'action';

  @override
  String get description =>
      'List the actions of an item (dispatcher.actions), or request one for the running server to start.';

  @override
  String get invocation => 'backlog action <id> ["<action name>"]';

  @override
  Future<int> run() async {
    if (args.rest.isEmpty || args.rest.length > 2) {
      throw UsageException('Expected an item id and optionally an action name.', usage);
    }
    final backlog = await openBacklog();
    final config =
        backlog.workflow.dispatcher ?? (throw const NotFoundException('No dispatcher is configured in backlog.yaml.'));
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[ItemReference.resolve(args.rest.first, snapshot.ids)]!;
    final status = planned.item.status;

    if (args.rest.length == 1) {
      if (json) {
        emitJson([
          for (final action in config.actions)
            {
              'name': action.name,
              'kind': action.kind.id,
              'offered': action.offeredIn(status),
              'on_enter': action.onEnter,
              'statuses': action.statuses,
              'agent': action.kind == ActionKind.prompt ? config.profileFor(action).name : null,
              'fresh': action.fresh,
            },
        ]);
        return 0;
      }
      final offered = [
        for (final action in config.actions)
          if (action.offeredIn(status)) action,
      ];
      if (offered.isEmpty) line('${planned.id} ($status) offers no actions.');
      for (final action in offered) {
        line(
          '${action.name}  —  ${action.summary}${action.onEnter == null ? '' : '; runs on entering ${action.onEnter}'}',
        );
      }
      final hooks = [
        for (final action in config.actions)
          if (!action.offeredIn(status) && action.onEnter != null) action,
      ];
      for (final hook in hooks) {
        line('(${hook.name} runs by itself on entering ${hook.onEnter})');
      }
      return 0;
    }

    final name = args.rest[1];
    final action =
        config.action(name) ??
        (throw NotFoundException('No action "$name" (configured: ${config.actions.map((a) => a.name).join(', ')}).'));
    if (!action.offeredIn(status)) {
      throw InvalidInputException('The action "${action.name}" is not offered for items in $status.');
    }
    final by = args.option('as') ?? context.environment['BACKLOG_AGENT'] ?? context.environment['USER'];
    await backlog.actionRequests.add(
      ActionRequest(item: planned.id.value, action: action.name, at: context.clock.now(), by: by),
    );
    if (json) {
      emitJson({'requested': true, 'item': planned.id.value, 'action': action.name});
    } else {
      line(
        'Requested "${action.name}" for ${planned.id}. A running backlog-server serving this backlog starts it; '
        'its result (or why it could not start) appears in the item\'s discussion.',
      );
    }
    return 0;
  }
}
