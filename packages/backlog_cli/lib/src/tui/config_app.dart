import 'package:backlog_core/backlog_core.dart';
import 'package:dart_tui/dart_tui.dart' show Cmd;

import 'doctor_page.dart';
import 'project_pages.dart';
import 'projects_page.dart';
import 'screen.dart';
import 'server_page.dart';
import 'widgets.dart';
import 'workflow_pages.dart';

/// Where `backlog config` finds things: the project registry file and the
/// server settings file (null without a location), `$HOME` for `~/` in
/// them, and the backlog found from the current folder (null when there is
/// none).
final class ConfigLocations {
  const ConfigLocations({
    this.registryFile,
    this.serverFile,
    this.home,
    this.currentBacklog,
    this.cwd = '.',
    this.environment = const {},
  });

  /// The environment (`PATH`, `HOME`, …) the doctor looks at.
  final Map<String, String> environment;

  /// The current folder, for folders typed relative to it.
  final String cwd;

  final String? registryFile;
  final String? serverFile;
  final String? home;
  final String? currentBacklog;
}

/// The first screen of `backlog config`: the two separate parts, Global
/// (this machine) and Project (one backlog's `backlog.yaml`).
Screen configRootScreen(ConfigLocations locations) => MenuScreen(
  'backlog config',
  intro: () => [
    'Global settings belong to this machine; project settings live in the',
    "project's backlog.yaml and are shared through its repository.",
  ],
  entries: () => [
    MenuEntry(
      'Global',
      detail: locations.registryFile == null
          ? 'no location: set HOME or pass --projects <file>'
          : 'this machine: project registry, server, doctor',
      enabled: locations.registryFile != null,
      onSelect: (_) => Navigator.task(() async {
        final screen = await _globalScreen(locations);
        return (navigator) => navigator.push(screen);
      }),
    ),
    MenuEntry(
      'Project',
      detail: 'backlog.yaml of a project from the registry or this folder',
      onSelect: (_) => Navigator.task(() async {
        final screen = await _projectPicker(locations);
        return (navigator) => navigator.push(screen);
      }),
    ),
  ],
);

Future<Screen> _globalScreen(ConfigLocations locations) async {
  final editor = registryConfigEditor(locations.registryFile!, home: locations.home);
  return ConfigFileScreen(
    'Global',
    editor,
    await editor.open(),
    sections: (screen) => [
      MenuEntry(
        'Projects',
        detail: 'the backlogs in the registry: add, remove, order (the default), ids, names, pins',
        enabled: screen.draft.isYaml,
        onSelect: (_) => Navigator.task(() async {
          final projects = ProjectsScreen(screen, home: locations.home, cwd: locations.cwd, problems: {});
          final problems = await ProjectsScreen.check([for (final entry in projects.settings.entries) entry.path]);
          return (navigator) => navigator.push(projects..problems.addAll(problems));
        }),
      ),
      MenuEntry(
        'Server',
        detail: switch (locations.serverFile) {
          final file? => 'addresses, port, allowed clients, token of backlog-server: $file',
          null => 'no location: set HOME or BACKLOG_SERVER_CONFIG',
        },
        enabled: locations.serverFile != null,
        onSelect: (_) => Navigator.task(() async {
          final editor = serverConfigEditor(locations.serverFile!, home: locations.home);
          final draft = await editor.open();
          return (navigator) => navigator.push(serverScreen(editor, draft));
        }),
      ),
      MenuEntry(
        'Doctor',
        detail: 'check the tools, the server, the projects and the worktrees of their dispatchers',
        onSelect: (_) => DoctorScreen.run(locations, (navigator, sections) {
          navigator.push(DoctorScreen(locations, sections));
        }),
      ),
    ],
  );
}

/// Picks the project whose `backlog.yaml` to edit: the backlog found here
/// first, then the registry in its order.
Future<Screen> _projectPicker(ConfigLocations locations) async {
  final current = locations.currentBacklog;
  var registry = ProjectRegistry.empty;
  String? registryProblem;
  if (locations.registryFile case final file?) {
    try {
      registry = await YamlProjectRegistryStore(file, home: locations.home).load();
    } on BacklogException catch (e) {
      registryProblem = e.message;
    }
  }
  final entries = <MenuEntry>[
    if (current != null) _projectEntry('This folder', current, registry.atPath(current)?.displayName),
    for (final entry in registry.entries)
      if (current == null || entry != registry.atPath(current))
        _projectEntry(entry.id, entry.path, entry.displayName, problem: await Backlog.problem(entry.path)),
  ];
  return MenuScreen(
    'Project',
    intro: () => [
      if (registryProblem != null) Look.red('Registry: $registryProblem'),
      if (entries.isEmpty) 'No backlog in this folder and no projects in the registry.',
      if (entries.isNotEmpty) 'Which project?',
    ],
    entries: () => entries,
  );
}

MenuEntry _projectEntry(String label, String root, String? name, {String? problem}) {
  final missing = problem != null && problem.startsWith('No ${BacklogLayout.configFileName}');
  final folderMissing = problem != null && problem.startsWith('Folder ');
  return MenuEntry(
    label,
    detail: [?name, root, ?problem].join('  '),
    enabled: !missing && !folderMissing,
    onSelect: (_) => Navigator.task(() async {
      final editor = projectConfigEditor(root);
      final draft = await editor.open();
      return (navigator) => navigator.push(
        ConfigFileScreen(
          name ?? ProjectRegistry.projectFolderName(root),
          editor,
          draft,
          sections: (screen) => [
            MenuEntry(
              'Workflow',
              detail: 'statuses, priorities, types, milestones, defaults, ids, claim lease',
              enabled: screen.draft.isYaml,
              onSelect: (navigator) {
                navigator.push(workflowScreen(screen));
                return null;
              },
            ),
            MenuEntry(
              'Views',
              detail: 'the saved views of the board: name, section, layout, grouping, columns, sort, filter',
              onSelect: (_) => openViews(root),
            ),
            MenuEntry(
              'Claims',
              detail: 'who holds which item, live or expired; release',
              onSelect: (_) => openClaims(root),
            ),
            MenuEntry('Lint', detail: 'problems of the backlog, with fixes', onSelect: (_) => openLint(root)),
            const MenuEntry('Appearance', detail: 'not yet: colours of the board', enabled: false),
            const MenuEntry('Dispatcher', detail: 'not yet: agents, worktrees, actions, pull requests', enabled: false),
          ],
        ),
      );
    }),
  );
}

/// The menu of one configuration file: its sections, *Edit a value…* and
/// *Review and save*. Every page under it edits the same [draft]; nothing
/// is written before the review, and leaving with unsaved edits asks
/// first.
final class ConfigFileScreen extends MenuScreen {
  ConfigFileScreen(
    super.title,
    this.editor,
    this.draft, {
    required List<MenuEntry> Function(ConfigFileScreen) sections,
    this.notes = const [],
  }) : _sections = sections;

  /// Lines about the file under its location.
  final List<String> notes;

  final ConfigEditor editor;
  ConfigDraft draft;
  final List<MenuEntry> Function(ConfigFileScreen) _sections;

  int get _changedLines =>
      draft.diff.where((line) => line.kind == DiffKind.added || line.kind == DiffKind.removed).length;

  @override
  List<String> get intro {
    final problem = editor.problem(draft);
    return [
      editor.location,
      ...notes,
      if (problem != null) Look.red(draft.changed ? 'Not valid: $problem' : 'The file is not valid: $problem'),
      if (!draft.isYaml) Look.red('It is not even YAML, so nothing can be edited here: fix it in a text editor.'),
      if (draft.changed) Look.yellow('Unsaved changes ($_changedLines changed lines).'),
    ];
  }

  @override
  List<MenuEntry> get entries => [
    ..._sections(this),
    MenuEntry('Edit a value…', detail: 'any key, e.g. claims.lease_minutes', onSelect: _editValue),
    MenuEntry(
      'Review and save',
      detail: draft.changed ? '$_changedLines changed lines' : 'no changes',
      onSelect: (navigator) {
        navigator.push(review());
        return null;
      },
    ),
  ];

  /// The shared review step for [draft].
  ReviewScreen review() => ReviewScreen(editor, draft, onSaved: (saved) => draft = saved);

  Cmd? _editValue(Navigator navigator) {
    navigator.push(_keyPrompt());
    return null;
  }

  PromptScreen _keyPrompt() => PromptScreen(
    'Edit a value',
    'Key path:',
    help: const [
      'Dots between keys, [n] for list entries, e.g. claims.lease_minutes or statuses[1].pickable.',
      'Unknown keys are allowed; the review says whether the file is still valid.',
    ],
    onSubmit: (text, navigator) {
      final path = parseConfigPath(text);
      final shown = formatConfigPath(path);
      navigator.push(
        PromptScreen(
          shown,
          'Value of $shown:',
          initial: formatConfigValue(draft.valueAt(path)),
          help: const ['YAML: 30, true, text, [a, b], {key: value}. Empty removes the key.'],
          onSubmit: (value, navigator) {
            if (value.trim().isEmpty) {
              navigator.say(draft.remove(path) ? 'Removed $shown (not saved yet).' : 'There is no $shown.');
            } else {
              draft.set(path, parseConfigValue(value));
              navigator.say('Set $shown (not saved yet; Review and save writes it).');
            }
            return null;
          },
        ),
      );
      return null;
    },
  );

  @override
  bool mayLeave(Navigator navigator) {
    if (!draft.changed) return true;
    navigator.push(
      ConfirmScreen(
        'Unsaved changes',
        'Leave $title without saving $_changedLines changed lines? (y: discard them, n: stay)',
        onYes: (navigator) {
          draft.reset();
          navigator.pop();
        },
      ),
    );
    return false;
  }
}
