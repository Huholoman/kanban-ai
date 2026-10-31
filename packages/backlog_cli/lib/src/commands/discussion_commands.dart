import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';

import '../render/text_output.dart';
import 'backlog_command.dart';

/// Shared by `comment` and `ask`: `<id> <text…>`, text `-` reads stdin, the
/// author is `--as`, `$BACKLOG_AGENT` or `$USER`.
abstract class _DiscussionCommand extends BacklogCommand {
  _DiscussionCommand(super.context) {
    argParser.addOption('as', help: 'Author (default: \$BACKLOG_AGENT, else \$USER).', valueHelp: 'name');
  }

  bool get question;

  /// Only a note (`comment --note`).
  bool get note => false;

  @override
  String get invocation => 'backlog $name <id> "<text>"   (text - reads standard input)';

  @override
  Future<int> run() async {
    if (args.rest.length < 2) throw UsageException('Expected an item id and the text.', usage);
    final author =
        args.option('as') ??
        context.environment['BACKLOG_AGENT'] ??
        context.environment['USER'] ??
        (throw UsageException('Say who you are: --as <name> or BACKLOG_AGENT.', usage));
    final words = args.rest.skip(1).toList();
    final text = words.length == 1 && words.single == '-'
        ? await (context.readInput ?? (throw UsageException('No standard input to read.', usage)))()
        : words.join(' ');
    final backlog = await openBacklog();
    final item = await backlog.items.comment(
      args.rest.first,
      author: author,
      text: text,
      question: question,
      note: note,
    );
    final snapshot = await backlog.planning.snapshot();
    if (json) {
      await emitItem(backlog, item.id, detail: true, snapshot: snapshot);
    } else {
      line(
        question
            ? 'Asked on ${item.id}; it waits for a person now. Stop here: you will be resumed with the answer.'
            : note
            ? 'Noted on ${item.id} (does not wake its agent or answer a question).'
            : 'Commented on ${item.id}.',
      );
      lines(TextOutput.rows([snapshot[item.id]!]));
    }
    return 0;
  }
}

final class CommentCommand extends _DiscussionCommand {
  CommentCommand(super.context) {
    argParser.addFlag(
      'note',
      negatable: false,
      help: 'Only a note: it does not answer an open question and does not wake the item\'s agent.',
    );
  }

  @override
  String get name => 'comment';

  @override
  String get description =>
      'Add a comment to the item\'s discussion (## Discussion at the end of its body); answers an open question.';

  @override
  bool get question => false;

  @override
  bool get note => args.flag('note');
}

final class AskCommand extends _DiscussionCommand {
  AskCommand(super.context);

  @override
  String get name => 'ask';

  @override
  String get description =>
      'Ask a person a question in the item\'s discussion; the item needs a person (not ready) until someone answers.';

  @override
  bool get question => true;
}

/// `backlog review <id> --ok|--changes "<text>"`: the verdict of a review as
/// a review comment (with the reviewed commit) in the item's discussion.
final class ReviewCommand extends BacklogCommand {
  ReviewCommand(super.context) {
    argParser
      ..addOption('as', help: 'Author (default: \$BACKLOG_AGENT, else \$USER).', valueHelp: 'name')
      ..addFlag('ok', negatable: false, help: 'Nothing to change (the text is a short summary, optional).')
      ..addFlag('changes', negatable: false, help: 'Changes needed: a summary, then the findings as a numbered list.')
      ..addOption(
        'commit',
        help: 'The reviewed commit (default: the head of the item\'s branch here).',
        valueHelp: 'rev',
      );
  }

  @override
  String get name => 'review';

  @override
  String get description =>
      'Record the verdict of a review of the item\'s work in its discussion (· review ok|changes, with the '
      'reviewed commit); it answers no question and wakes no agent.';

  @override
  String get invocation =>
      'backlog review <id> (--ok ["<summary>"] | --changes "<summary and numbered findings>")   (text - reads standard input)';

  @override
  Future<int> run() async {
    final ok = args.flag('ok');
    if (ok == args.flag('changes')) throw UsageException('Give exactly one of --ok and --changes.', usage);
    if (args.rest.isEmpty) throw UsageException('Expected an item id.', usage);
    final author =
        args.option('as') ??
        context.environment['BACKLOG_AGENT'] ??
        context.environment['USER'] ??
        (throw UsageException('Say who you are: --as <name> or BACKLOG_AGENT.', usage));
    final words = args.rest.skip(1).toList();
    final text = words.length == 1 && words.single == '-'
        ? await (context.readInput ?? (throw UsageException('No standard input to read.', usage)))()
        : words.join(' ');
    final backlog = await openBacklog();
    final outcome = await ReviewRecorder(environment: context.environment.isEmpty ? null : context.environment).record(
      backlog,
      args.rest.first,
      author: author,
      verdict: ok ? ReviewVerdict.ok : ReviewVerdict.changes,
      text: text,
      workingDirectory: context.cwd,
      commit: args.option('commit'),
    );
    final id = outcome.item.id;
    final snapshot = await backlog.planning.snapshot();
    if (json) {
      await emitItem(backlog, id, detail: true, snapshot: snapshot);
    } else {
      final comment = outcome.comment;
      final of = comment.commit == null ? '' : ' of ${comment.commit}';
      line(ok ? 'Reviewed $id$of: ok.' : 'Reviewed $id$of: changes needed (${comment.findings} numbered finding(s)).');
      lines(TextOutput.rows([snapshot[id]!]));
    }
    return 0;
  }
}
