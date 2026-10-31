import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../render/json_output.dart';
import '../render/text_output.dart';
import '../where.dart';
import 'backlog_command.dart';

final class ReadyCommand extends BacklogCommand {
  ReadyCommand(super.context) {
    argParser.addMultiOption('where', abbr: 'w', splitCommas: false, help: 'Narrow down, e.g. labels=infra.');
  }

  @override
  String get name => 'ready';

  @override
  String get description =>
      'Items an agent can start now: pickable, unblocked, no overlapping work in progress, unclaimed, no open children.';

  @override
  Future<int> run() async {
    final filter = combineWhere(args.multiOption('where'));
    final snapshot = await (await openBacklog()).planning.snapshot();
    emitItems(snapshot.ready.where(filter.matches).toList());
    return 0;
  }
}

final class BlockedCommand extends BacklogCommand {
  BlockedCommand(super.context);

  @override
  String get name => 'blocked';

  @override
  String get description => 'Unfinished items waiting for other items.';

  @override
  Future<int> run() async {
    emitItems((await (await openBacklog()).planning.snapshot()).blocked);
    return 0;
  }
}

final class NextCommand extends BacklogCommand {
  NextCommand(super.context) {
    addAgentOption();
    argParser.addMultiOption('where', abbr: 'w', splitCommas: false, help: 'Only consider matching items.');
  }

  @override
  String get name => 'next';

  @override
  String get description => 'Claim the most urgent ready item. Exits with 2 when there is nothing to do.';

  @override
  Future<int> run() async {
    final filter = combineWhere(args.multiOption('where'));
    final backlog = await openBacklog();
    final outcome = await backlog.claims.claimNext(agent, where: filter.matches);
    if (outcome == null) {
      json ? emitJson(null) : line('Nothing ready.');
      return 2;
    }
    await emitItem(backlog, outcome.item.id, detail: true);
    return 0;
  }
}

final class ClaimCommand extends BacklogCommand {
  ClaimCommand(super.context) {
    addAgentOption();
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Claim even when blocked, waiting for overlapping work or with open children.',
    );
  }

  @override
  String get name => 'claim';

  @override
  String get description => 'Take an item: lock it for you and move it to in-progress.';

  @override
  String get invocation => 'backlog claim <id> --as <agent>';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final outcome = await backlog.claims.claim(singleArgument('item id'), agent, force: args.flag('force'));
    final note = outcome.tookOver == null ? '' : ' (took over expired claim of ${outcome.tookOver!.agent})';
    await emitItem(backlog, outcome.item.id, message: 'Claimed ${outcome.item.id} for ${outcome.claim.agent}$note');
    return 0;
  }
}

final class HeartbeatCommand extends BacklogCommand {
  HeartbeatCommand(super.context) {
    addAgentOption();
  }

  @override
  String get name => 'heartbeat';

  @override
  String get description => 'Extend your claim during long work so that it does not expire.';

  @override
  String get invocation => 'backlog heartbeat <id> --as <agent>';

  @override
  Future<int> run() async {
    final claim = await (await openBacklog()).claims.heartbeat(singleArgument('item id'), agent);
    json
        ? emitJson(JsonOutput.claim(claim))
        : line('${claim.itemId} claimed by ${claim.agent} until ${TextOutput.time(claim.expiresAt)}');
    return 0;
  }
}

final class ReleaseCommand extends BacklogCommand {
  ReleaseCommand(super.context) {
    addAgentOption(mandatory: false);
    argParser
      ..addOption('status', help: 'Status to leave the item in (default: back to the pickable one).')
      ..addFlag('force', negatable: false, help: 'Drop a claim held by somebody else.');
  }

  @override
  String get name => 'release';

  @override
  String get description => 'Give an unfinished item back.';

  @override
  String get invocation => 'backlog release <id> [--as <agent>]';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final item = await backlog.claims.release(
      singleArgument('item id'),
      agent: optionalAgent,
      status: args.option('status'),
      force: args.flag('force'),
    );
    await emitItem(backlog, item.id, message: 'Released ${item.id}');
    return 0;
  }
}

final class DoneCommand extends BacklogCommand {
  DoneCommand(super.context) {
    addAgentOption(mandatory: false);
    argParser
      ..addOption('status', help: 'A done-category status, e.g. cancelled.')
      ..addFlag('force', negatable: false, help: 'Even when somebody else holds the claim.');
  }

  @override
  String get name => 'done';

  @override
  String get description => 'Finish an item and drop its claim.';

  @override
  String get invocation => 'backlog done <id> [--as <agent>]';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final item = await backlog.claims.complete(
      singleArgument('item id'),
      agent: optionalAgent,
      status: args.option('status'),
      force: args.flag('force'),
    );
    await emitItem(backlog, item.id, message: 'Finished ${item.id}');
    final unblocked = (await backlog.planning.snapshot())
        .dependentsOf(item.id)
        .where((planned) => planned.isReady)
        .toList();
    if (!json && unblocked.isNotEmpty) {
      line('Now ready: ${unblocked.map((p) => p.id).join(', ')}');
    }
    return 0;
  }
}

final class ClaimsCommand extends BacklogCommand {
  ClaimsCommand(super.context);

  @override
  String get name => 'claims';

  @override
  String get description => 'Who works on what right now.';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final now = context.clock.now();
    final claims = await backlog.claims.all();
    if (json) {
      emitJson([for (final claim in claims) JsonOutput.claim(claim, expired: claim.isExpiredAt(now))]);
    } else if (claims.isEmpty) {
      line('No claims.');
    } else {
      for (final claim in claims) {
        line(
          '${claim.itemId}  ${claim.agent}  '
          '${claim.isExpiredAt(now) ? 'EXPIRED' : 'until'} ${TextOutput.time(claim.expiresAt)}',
        );
      }
    }
    return 0;
  }
}

final class PrCommand extends BacklogCommand {
  PrCommand(super.context) {
    argParser
      ..addOption('description', abbr: 'd', help: 'The pull request\'s description.', valueHelp: 'text')
      ..addOption(
        'description-file',
        help: 'Read the description from a file (- reads standard input).',
        valueHelp: 'file',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'After a rebase: replace the remote branch (--force-with-lease; only the item\'s branch, never the '
            'base).',
      );
  }

  @override
  String get name => 'pr';

  @override
  String get description =>
      'Push the item\'s branch and open its pull request (dispatcher.pr in backlog.yaml); the URL goes into pr. '
      'When the item has one already, it only pushes. Run it in the item\'s worktree.';

  @override
  String get invocation => 'backlog pr <id> [--description "<text>" | --description-file <file|->] [--force]';

  @override
  Future<int> run() async {
    final id = singleArgument('item id');
    final text = args.option('description');
    final file = args.option('description-file');
    if (text != null && file != null) {
      throw UsageException('Give --description or --description-file, not both.', usage);
    }
    final description =
        text ??
        switch (file) {
          null => null,
          '-' => await (context.readInput ?? (throw UsageException('No standard input to read.', usage)))(),
          final path => await File(p.join(context.cwd, path)).readAsString(),
        };
    final backlog = await openBacklog();
    final outcome = await PullRequestOpener(
      environment: context.environment.isEmpty ? null : context.environment,
    ).open(backlog, id, workingDirectory: context.cwd, description: description, force: args.flag('force'));
    if (json) {
      emitJson({
        'url': outcome.url,
        'created': outcome.created,
        'branch': outcome.branch,
        'base': outcome.base,
        'remote': outcome.remote,
      });
    } else {
      line(
        outcome.created
            ? 'Pushed ${outcome.branch} to ${outcome.remote} and opened ${outcome.url} (into ${outcome.base}).'
            : 'Pushed ${outcome.branch} to ${outcome.remote}; the pull request exists: ${outcome.url}',
      );
    }
    return 0;
  }
}
