import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../tui/config_app.dart';
import '../tui/screen.dart';
import 'backlog_command.dart';

/// `backlog config`: the configuration TUI (global × project).
final class ConfigCommand extends BacklogCommand {
  ConfigCommand(super.context) {
    argParser.addOption(
      'projects',
      valueHelp: 'file',
      help: 'Registry file (default: \$BACKLOG_PROJECTS, else \$XDG_CONFIG_HOME/kanban-ai/projects.yaml).',
    );
  }

  @override
  String get name => 'config';

  @override
  String get description =>
      'Edit the configuration in a terminal UI: Global (this machine: the project registry, the server) and Project '
      "(a project's backlog.yaml). Changes are shown as a diff, validated and written only after confirmation.";

  @override
  Future<int> run() async {
    if (args.rest.isNotEmpty) throw UsageException('`config` takes no arguments.', usage);
    final runTui = context.runTui ?? (throw UsageException('`backlog config` needs an interactive terminal.', usage));
    final registry = args.option('projects') ?? projectRegistryFile(context.environment);
    String? current;
    try {
      current = backlogRoot;
    } on NotFoundException {
      current = null;
    }
    await runTui(
      Navigator(
        configRootScreen(
          ConfigLocations(
            registryFile: registry == null ? null : p.normalize(p.join(context.cwd, registry)),
            serverFile: switch (serverConfigFile(context.environment)) {
              final file? => p.normalize(p.join(context.cwd, file)),
              null => null,
            },
            home: context.environment['HOME'],
            currentBacklog: current,
          ),
        ),
      ),
    );
    return 0;
  }
}
