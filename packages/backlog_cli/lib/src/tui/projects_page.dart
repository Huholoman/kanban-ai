import 'package:backlog_core/backlog_core.dart' show Backlog, RegistryEntry, RegistrySettings;
import 'package:dart_tui/dart_tui.dart' show Cmd;
import 'package:path/path.dart' as p;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Global › Projects*: the projects of the registry [file] in order (the
/// first is the default), whether each opens, and *Add a project…*. Every
/// project has its own menu; everything edits [file]'s draft.
final class ProjectsScreen extends MenuScreen {
  ProjectsScreen(this.file, {required this.home, required this.cwd, required this.problems}) : super('Projects');

  final ConfigFileScreen file;
  final String? home;

  /// Relative folders typed in *Add a project…* start here.
  final String cwd;

  /// What is wrong with each project folder (null: it opens), by path.
  final Map<String, String?> problems;

  RegistrySettings get settings => RegistrySettings(file.draft, baseDir: p.dirname(file.editor.location), home: home);

  /// Checks [paths] (backlogs opened in the background) for [problems].
  static Future<Map<String, String?>> check(Iterable<String> paths) async => {
    for (final path in paths)
      if (path.isNotEmpty) path: await Backlog.problem(path),
  };

  @override
  List<String> get intro => [
    if (file.editor.problem(file.draft) case final problem?) Look.red('Not valid: $problem'),
    if (file.draft.changed) Look.yellow('Unsaved changes.'),
    'The backlogs backlog-server hosts; the first one is the default project.',
  ];

  @override
  List<MenuEntry> get entries {
    final all = settings.entries;
    return [
      for (final (i, entry) in all.indexed)
        MenuEntry(
          entry.id,
          detail: _detail(entry, isDefault: i == 0),
          onSelect: (navigator) {
            navigator.push(_ProjectScreen(this, i));
            return null;
          },
        ),
      MenuEntry(
        'Add a project…',
        detail: 'a backlog folder (the one with backlog.yaml)',
        onSelect: (navigator) {
          navigator.push(
            PromptScreen(
              'Add a project',
              'Backlog folder (absolute, ~/… or relative to $cwd):',
              onSubmit: (text, navigator) {
                final typed = text.trim();
                final path = typed.startsWith('~') || typed.isEmpty ? typed : p.normalize(p.join(cwd, typed));
                final id = settings.add(path);
                final added = settings.entries.last.path;
                navigator.say('Added $id (not saved yet).');
                return Navigator.task(() async {
                  final checked = await check([added]);
                  return (_) => problems.addAll(checked);
                });
              },
            ),
          );
          return null;
        },
      ),
      MenuEntry(
        'Review and save',
        detail: file.draft.changed ? 'see the changes, then save' : 'no changes',
        onSelect: (navigator) {
          navigator.push(file.review());
          return null;
        },
      ),
    ];
  }

  String _detail(RegistryEntry entry, {required bool isDefault}) => [
    entry.displayName,
    entry.path,
    if (isDefault) 'default',
    if (entry.pinned) 'pinned',
    switch (problems[entry.path]) {
      _ when !problems.containsKey(entry.path) => 'not checked',
      null => Look.green('opens'),
      final problem => Look.red(problem),
    },
  ].join('  ');
}

/// The menu of one project: id, name, pinned, default, order, remove.
final class _ProjectScreen extends MenuScreen {
  _ProjectScreen(this.list, this.index) : super('');

  final ProjectsScreen list;
  int index;

  RegistrySettings get _settings => list.settings;

  RegistryEntry? get _entry {
    final all = _settings.entries;
    return index < all.length ? all[index] : null;
  }

  @override
  String get title => _entry?.id ?? '?';

  @override
  List<String> get intro => [
    if (_entry case final entry?) ...[
      entry.path,
      switch (list.problems[entry.path]) {
        _ when !list.problems.containsKey(entry.path) => 'Not checked yet.',
        null => Look.green('The backlog opens.'),
        final problem => Look.red(problem),
      },
    ],
  ];

  @override
  List<MenuEntry> get entries {
    final entry = _entry;
    if (entry == null) return const [];
    final count = _settings.entries.length;
    final id = entry.id;
    return [
      MenuEntry(
        'Id…',
        detail: '$id${entry.idWritten ? '' : ' (from the folder)'}: in the URLs of the board and the API',
        onSelect: (navigator) =>
            _prompt(navigator, 'Id of $id', 'New id (lower-case letters, digits, - and _):', id, (text) {
              _settings.setId(index, text);
              return 'Project $id is now ${text.trim()} (not saved yet).';
            }),
      ),
      MenuEntry(
        'Name…',
        detail: entry.name ?? '${entry.displayName} (the folder; Enter to give one)',
        onSelect: (navigator) =>
            _prompt(navigator, 'Name of $id', 'Name on the board (empty: the folder name):', entry.name ?? '', (text) {
              _settings.setName(index, text);
              return 'Name of $id set (not saved yet).';
            }),
      ),
      MenuEntry(
        'Pinned',
        detail: entry.pinned ? 'yes: offered first on the board (Enter: no)' : 'no (Enter: yes, offered first)',
        onSelect: (navigator) {
          _settings.setPinned(index, !entry.pinned);
          navigator.say('$id is ${entry.pinned ? 'not ' : ''}pinned (not saved yet).');
          return null;
        },
      ),
      MenuEntry(
        'Make default',
        detail: index == 0 ? 'it is the default project' : 'move it to the top: the board opens it first',
        enabled: index > 0,
        onSelect: (navigator) => _move(navigator, 0),
      ),
      MenuEntry(
        'Move up',
        detail: 'position ${index + 1} of $count',
        enabled: index > 0,
        onSelect: (navigator) => _move(navigator, index - 1),
      ),
      MenuEntry(
        'Move down',
        detail: 'position ${index + 1} of $count',
        enabled: index < count - 1,
        onSelect: (navigator) => _move(navigator, index + 1),
      ),
      MenuEntry(
        'Remove',
        detail: 'from the registry only; the folder stays',
        onSelect: (navigator) {
          navigator.push(
            ConfirmScreen(
              'Remove $id',
              'Remove $id from the registry? The folder stays. (y: remove, n: keep)',
              onYes: (navigator) {
                _settings.remove(index);
                navigator
                  ..pop()
                  ..say('Removed $id (not saved yet).');
              },
            ),
          );
          return null;
        },
      ),
    ];
  }

  Cmd? _move(Navigator navigator, int to) {
    _settings.move(index, to);
    index = to;
    navigator.say('Moved $title to position ${to + 1} (not saved yet).');
    return null;
  }

  Cmd? _prompt(Navigator navigator, String title, String label, String initial, String Function(String) apply) {
    navigator.push(
      PromptScreen(
        title,
        label,
        initial: initial,
        onSubmit: (text, navigator) {
          navigator.say(apply(text));
          return null;
        },
      ),
    );
    return null;
  }
}
