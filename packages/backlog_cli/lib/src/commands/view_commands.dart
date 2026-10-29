import 'package:backlog_core/backlog_core.dart';

import '../agent_instructions.dart';
import '../render/json_output.dart';
import '../render/text_output.dart';
import 'backlog_command.dart';

final class ViewCommand extends BacklogCommand {
  ViewCommand(super.context);

  @override
  String get name => 'view';

  @override
  String get description => 'Run a saved view from views/; without a name, list them.';

  @override
  String get invocation => 'backlog view [name]';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    if (args.rest.isEmpty) {
      final views = await backlog.views.all();
      if (json) {
        emitJson([
          for (final view in views)
            {'id': view.id, 'name': view.name, 'layout': view.layout.name, 'section': view.section},
        ]);
      } else {
        final sections = {for (final view in views) ?view.section}.toList()..sort();
        for (final section in [null, ...sections]) {
          final members = views.where((view) => view.section == section);
          if (members.isEmpty) continue;
          if (section != null) line('\n$section:');
          for (final view in members) {
            line('${section == null ? '' : '  '}${view.id.padRight(16)} ${view.name} (${view.layout.name})');
          }
        }
      }
      return 0;
    }
    final result = await backlog.views.run(singleArgument('view name'));
    json ? emitJson(JsonOutput.view(result)) : lines(TextOutput.view(result));
    return 0;
  }
}

final class LintCommand extends BacklogCommand {
  LintCommand(super.context);

  @override
  String get name => 'lint';

  @override
  String get description =>
      'Check the backlog for broken files, unknown values, dangling references, cycles and stale claims. Exits with 1 on errors.';

  @override
  Future<int> run() async {
    final issues = await (await openBacklog()).linter.run();
    final errors = issues.where((i) => i.severity == Severity.error).length;
    if (json) {
      emitJson([for (final issue in issues) JsonOutput.lintIssue(issue)]);
    } else {
      issues.map(TextOutput.lintIssue).forEach(line);
      line(issues.isEmpty ? 'All good.' : '$errors error(s), ${issues.length - errors} warning(s).');
    }
    return errors > 0 ? 1 : 0;
  }
}

final class InstructionsCommand extends BacklogCommand {
  InstructionsCommand(super.context);

  @override
  String get name => 'instructions';

  @override
  String get description => 'Print the workflow guide for coding agents (Markdown).';

  @override
  Future<int> run() async {
    json ? emitJson({'markdown': agentInstructions}) : line(agentInstructions);
    return 0;
  }
}
