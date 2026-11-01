import 'package:backlog_core/backlog_core.dart'
    show BacklogException, DispatcherSettings, DoctorLevel, WorktreeSetting, checkWorktree, previewDispatcher;
import 'package:dart_tui/dart_tui.dart' show Cmd;
import 'package:path/path.dart' as p;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Dispatcher*: mode, limits, worktrees (listed, checked, on demand), base
/// branch, agent profile and a preview of the command it starts; all in
/// [file]'s draft.
Screen dispatcherScreen(ConfigFileScreen file) {
  DispatcherSettings settings() => DispatcherSettings(file.draft);
  final root = p.dirname(file.editor.location);
  MenuEntry text(String label, String key, String question, {String? otherwise, List<String> help = const []}) =>
      MenuEntry(
        label,
        detail: settings().text(key) ?? otherwise ?? 'none',
        onSelect: (navigator) =>
            _prompt(navigator, label, question, settings().text(key) ?? '', [...help, 'Empty removes it.'], (value) {
              if (DispatcherSettings.numberKeys.contains(key)) {
                settings().setNumber(key, value);
              } else {
                settings().setText(key, value);
              }
              return '$label set (not saved yet).';
            }),
      );
  return MenuScreen(
    'Dispatcher',
    intro: () => [
      if (file.editor.problem(file.draft) case final problem?) Look.red('Not valid: $problem'),
      if (file.draft.changed) Look.yellow('Unsaved changes.'),
      if (!settings().enabled) 'No dispatcher yet: adding a worktree (or a repository) turns it on.',
    ],
    entries: () => [
      _choice(
        'Mode',
        settings().mode == 'auto' ? 'auto: ready work starts by itself' : 'manual: agents start from the board',
        const ['manual', 'auto'],
        settings().mode,
        (mode) {
          settings().setMode(mode);
          return 'Mode $mode (not saved yet).';
        },
      ),
      text('Max agents', 'max_agents', 'At most this many agents at once:', otherwise: 'as many as worktrees'),
      MenuEntry(
        'Worktrees',
        detail: settings().worktrees.isEmpty
            ? 'none listed'
            : settings().worktrees.map((worktree) => worktree.name).join(', '),
        onSelect: (navigator) {
          navigator.push(_WorktreesScreen(file, root));
          return null;
        },
      ),
      text(
        'Repository',
        'repo',
        'Primary clone to add worktrees from when none is free (absolute or relative to the backlog):',
        otherwise: 'none: only the listed worktrees',
      ),
      text(
        'Worktree name',
        'worktree_name',
        'Name of added worktrees, with {n} (and {repo}):',
        otherwise: '{repo}-{n}',
      ),
      text('Max worktrees', 'max_worktrees', 'At most this many worktrees, listed and added:'),
      text(
        'Cleanup after days',
        'cleanup_after_days',
        'Remove added worktrees idle this many days:',
        otherwise: 'keep them',
      ),
      text('Base branch', 'base', 'Branch new agent branches start from:', otherwise: 'main'),
      _choice('Agent', 'profile ${settings().agent}', settings().profiles, settings().agent, (name) {
        settings().setAgent(name);
        return 'Agent $name (not saved yet).';
      }),
      MenuEntry(
        'Command preview',
        detail: 'what an agent would be started with, placeholders filled in',
        onSelect: (navigator) {
          navigator.push(TextScreen('Command preview', () => _preview(file, root)));
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
    ],
  );
}

List<String> _preview(ConfigFileScreen file, String root) {
  try {
    final preview = previewDispatcher(file.draft.text, backlogRoot: root);
    if (preview == null) return ['No dispatcher section yet.'];
    return [
      'Profile ${preview.profile}, for an example item in the first worktree:',
      for (final MapEntry(:key, :value) in preview.values.entries) Look.dim('  {$key} = $value'),
      '',
      Look.bold('Command'),
      ..._wrap(preview.command),
      '',
      Look.bold('Prompt ({prompt})'),
      ...preview.prompt.trimRight().split('\n').expand(_wrap),
    ];
  } on BacklogException catch (e) {
    return [Look.red('Not valid: ${e.message}')];
  }
}

/// [line] in pieces of at most [width] characters.
Iterable<String> _wrap(String line, {int width = 96}) sync* {
  if (line.isEmpty) yield '';
  for (var start = 0; start < line.length; start += width) {
    yield line.substring(start, start + width > line.length ? line.length : start + width);
  }
}

Cmd? _prompt(
  Navigator navigator,
  String title,
  String label,
  String initial,
  List<String> help,
  String Function(String) apply,
) {
  navigator.push(
    PromptScreen(
      title,
      label,
      initial: initial,
      help: help,
      onSubmit: (text, navigator) {
        navigator.say(apply(text));
        return null;
      },
    ),
  );
  return null;
}

MenuEntry _choice(String label, String detail, List<String> options, String current, String Function(String) pick) =>
    MenuEntry(
      label,
      detail: detail,
      onSelect: (navigator) {
        navigator.push(
          MenuScreen(
            label,
            entries: () => [
              for (final option in options)
                MenuEntry(
                  option == current ? '$option  ✓' : option,
                  onSelect: (navigator) {
                    navigator
                      ..pop()
                      ..say(pick(option));
                    return null;
                  },
                ),
            ],
          ),
        );
        return null;
      },
    );

/// The listed worktrees with the result of checking each (exists, git,
/// clean), *Add a worktree…* and *Check all*.
final class _WorktreesScreen extends MenuScreen {
  _WorktreesScreen(this.file, this.root) : super('Worktrees');

  final ConfigFileScreen file;
  final String root;
  final Map<String, String> _checked = {};

  DispatcherSettings get _settings => DispatcherSettings(file.draft);

  String _path(WorktreeSetting worktree) => p.normalize(p.join(root, worktree.path));

  @override
  List<String> get intro => [
    'Folders agents work in; a worktree is free when nobody holds a claim under its name.',
    Look.dim('Paths are absolute or relative to $root.'),
  ];

  @override
  List<MenuEntry> get entries {
    final all = _settings.worktrees;
    return [
      for (final (i, worktree) in all.indexed)
        MenuEntry(
          worktree.name,
          detail: [_path(worktree), ?_checked[_path(worktree)]].join('  '),
          onSelect: (navigator) {
            navigator.push(_worktreeMenu(i, worktree));
            return null;
          },
        ),
      MenuEntry(
        'Add a worktree…',
        detail: 'a name; the folder defaults to ../<name>',
        onSelect: (navigator) =>
            _prompt(navigator, 'Add a worktree', 'Name (also the agent name):', '', const [], (name) {
              navigator.push(
                PromptScreen(
                  'Folder of ${name.trim()}',
                  'Folder (empty: ../${name.trim()}):',
                  onSubmit: (path, navigator) {
                    _settings.addWorktree(name, path: path);
                    navigator.say('Added worktree ${name.trim()} (not saved yet).');
                    return _check(all.length);
                  },
                ),
              );
              return 'Where is ${name.trim()}?';
            }),
      ),
      MenuEntry(
        'Check all',
        detail: 'whether each folder exists, is a git worktree and is clean',
        onSelect: (_) => _checkAll(),
      ),
    ];
  }

  Screen _worktreeMenu(int index, WorktreeSetting worktree) => MenuScreen(
    worktree.name,
    intro: () => [_path(worktree), ?_checked[_path(worktree)]],
    entries: () => [
      MenuEntry(
        'Folder…',
        detail: worktree.path,
        onSelect: (navigator) => _prompt(
          navigator,
          'Folder of ${worktree.name}',
          'Folder (empty: ../${worktree.name}):',
          worktree.path,
          const [],
          (path) {
            _settings.setWorktreePath(index, path);
            return 'Folder of ${worktree.name} set (not saved yet).';
          },
        ),
      ),
      MenuEntry('Check', detail: 'exists, git worktree, clean', onSelect: (_) => _check(index)),
      MenuEntry(
        'Remove',
        detail: 'from the list only; the folder stays',
        onSelect: (navigator) {
          _settings.removeWorktree(index);
          navigator
            ..pop()
            ..say('Removed worktree ${worktree.name} (not saved yet).');
          return null;
        },
      ),
    ],
  );

  Cmd _check(int index) => Navigator.task(() async {
    final worktree = _settings.worktrees[index];
    final finding = await checkWorktree(worktree.name, _path(worktree));
    return (navigator) {
      _checked[_path(worktree)] = _shown(finding.level, finding.detail);
      navigator.say('${worktree.name}: ${finding.detail}', error: finding.level == DoctorLevel.error);
    };
  });

  Cmd _checkAll() => Navigator.task(() async {
    final results = {
      for (final worktree in _settings.worktrees) _path(worktree): await checkWorktree(worktree.name, _path(worktree)),
    };
    return (navigator) {
      results.forEach((path, finding) => _checked[path] = _shown(finding.level, finding.detail));
      navigator.say('Checked ${results.length} worktrees.');
    };
  });

  static String _shown(DoctorLevel level, String detail) => switch (level) {
    DoctorLevel.ok => Look.green('✓ clean'),
    DoctorLevel.warning => Look.yellow('! ${detail.replaceFirst(RegExp(r'^\S+ '), '')}'),
    _ => Look.red('✗ ${detail.replaceFirst(RegExp(r'^\S+ '), '')}'),
  };
}
