import 'package:args/command_runner.dart';

import '../render/text_output.dart';
import 'backlog_command.dart';

/// Shared by `comment` and `ask`: `<id> <text…>`, text `-` reads stdin, the
/// author is `--as`, `$BACKLOG_AGENT` or `$USER`.
abstract class _DiscussionCommand extends BacklogCommand {
  _DiscussionCommand(super.context) {
    argParser.addOption('as', help: 'Author (default: \$BACKLOG_AGENT, else \$USER).', valueHelp: 'name');
  }

  bool get question;

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
    final item = await backlog.items.comment(args.rest.first, author: author, text: text, question: question);
    final snapshot = await backlog.planning.snapshot();
    if (json) {
      await emitItem(backlog, item.id, detail: true, snapshot: snapshot);
    } else {
      line(
        question
            ? 'Asked on ${item.id}; it waits for a person now. Stop here: you will be resumed with the answer.'
            : 'Commented on ${item.id}.',
      );
      lines(TextOutput.rows([snapshot[item.id]!]));
    }
    return 0;
  }
}

final class CommentCommand extends _DiscussionCommand {
  CommentCommand(super.context);

  @override
  String get name => 'comment';

  @override
  String get description =>
      'Add a comment to the item\'s discussion (## Discussion at the end of its body); answers an open question.';

  @override
  bool get question => false;
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
