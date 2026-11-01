import 'package:path/path.dart' as p;

import '../../workflow/domain/dispatcher_config.dart';
import '../../workflow/infrastructure/yaml_workflow.dart';

/// What the dispatcher of a `backlog.yaml` [source] would start for an
/// example item in its first worktree: the agent profile, the command line
/// with every placeholder filled in, and the prompt.
final class DispatcherPreview {
  const DispatcherPreview({required this.profile, required this.command, required this.prompt, required this.values});

  final String profile;

  /// The command as one shell-quoted line.
  final String command;
  final String prompt;

  /// The example values of the placeholders.
  final Map<String, String> values;
}

/// The preview of the dispatcher in [source] (the backlog folder is
/// [backlogRoot]); null without a dispatcher section. Throws
/// `ConfigurationException` when [source] is not valid.
DispatcherPreview? previewDispatcher(String source, {required String backlogRoot}) {
  final workflow = parseWorkflowYaml(source);
  final config = workflow.dispatcher;
  if (config == null) return null;
  final worktree =
      config.worktrees.firstOrNull ??
      config.newWorktrees?.worktree(config.newWorktrees!.nameFor(2), backlogRoot) ??
      WorktreeDefinition('worktree', '../worktree');
  final id = '${workflow.idPrefix}-${'7f3a2b9c1d0e'.substring(0, workflow.idLength)}';
  final values = {
    'id': id,
    'title': 'Example item',
    'worktree': worktree.name,
    'path': worktree.resolvePath(backlogRoot),
    'backlog': p.normalize(p.absolute(backlogRoot)),
    'branch': 'agent/$id',
  };
  final prompt = config.prompt.render(values);
  return DispatcherPreview(
    profile: config.agent.name,
    command: CommandTemplate.join(config.agent.command.render({...values, 'prompt': prompt})),
    prompt: prompt,
    values: values,
  );
}
