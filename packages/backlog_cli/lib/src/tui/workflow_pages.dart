import 'package:backlog_core/backlog_core.dart'
    show InvalidInputException, StatusCategory, WorkflowEntry, WorkflowList, WorkflowSettings;
import 'package:dart_tui/dart_tui.dart' show Cmd;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// The *Workflow* page of a project: statuses, priorities, types,
/// milestones, defaults, the id format and the claim lease. Every page
/// edits [file]'s draft through [WorkflowSettings]; nothing is written
/// before *Review and save*.
Screen workflowScreen(ConfigFileScreen file) {
  WorkflowSettings settings() => WorkflowSettings(file.draft);
  return MenuScreen(
    'Workflow',
    intro: () => _problem(file),
    entries: () {
      final s = settings();
      return [
        for (final list in WorkflowList.values)
          MenuEntry(
            _label(list),
            detail: _summary(s, list),
            onSelect: (navigator) => _push(navigator, _listScreen(file, list)),
          ),
        MenuEntry(
          'Defaults',
          detail: [
            for (final list in WorkflowList.values)
              if (list.hasDefault) '${list.singular} ${s.effectiveDefault(list) ?? '–'}',
          ].join(' · '),
          onSelect: (navigator) => _push(navigator, _defaultsScreen(file)),
        ),
        MenuEntry(
          'ID prefix',
          detail: '${s.idPrefix}: new items get ids like ${s.idPrefix}-${'7f3a2b9c1d0e'.substring(0, s.idLength ?? 4)}',
          onSelect: (navigator) => _prompt(
            navigator,
            'ID prefix',
            'Prefix of new ids (letters and digits, starting with a letter):',
            initial: s.idPrefix,
            help: const ['Existing items keep their ids.'],
            onSubmit: (text) {
              settings().setIdPrefix(text);
              return 'ID prefix ${text.trim()} (not saved yet).';
            },
          ),
        ),
        MenuEntry(
          'ID length',
          detail: '${s.idLength ?? 'not a number'} characters after the prefix',
          onSelect: (navigator) => _prompt(
            navigator,
            'ID length',
            'Characters after the prefix (3 to 12):',
            initial: '${s.idLength ?? ''}',
            onSubmit: (text) {
              settings().setIdLength(_number(text));
              return 'ID length ${text.trim()} (not saved yet).';
            },
          ),
        ),
        MenuEntry(
          'Claim lease',
          detail: '${s.leaseMinutes ?? 'not a number'} minutes: a claim without heartbeat expires after this',
          onSelect: (navigator) => _prompt(
            navigator,
            'Claim lease',
            'Minutes a claim lasts without heartbeat:',
            initial: '${s.leaseMinutes ?? ''}',
            onSubmit: (text) {
              settings().setLeaseMinutes(_number(text));
              return 'Claim lease ${text.trim()} minutes (not saved yet).';
            },
          ),
        ),
        _reviewEntry(file),
      ];
    },
  );
}

String _label(WorkflowList list) => switch (list) {
  WorkflowList.statuses => 'Statuses',
  WorkflowList.priorities => 'Priorities',
  WorkflowList.types => 'Types',
  WorkflowList.milestones => 'Milestones',
};

String _summary(WorkflowSettings settings, WorkflowList list) {
  final ids = settings.ids(list);
  if (ids.isEmpty) return list == WorkflowList.milestones ? 'none: any milestone name is allowed' : 'none';
  return '${ids.join(', ')}${settings.isBuiltIn(list) ? '  (built-in)' : ''}';
}

/// What is wrong with the draft as a whole, above every page.
List<String> _problem(ConfigFileScreen file) => [
  if (file.editor.problem(file.draft) case final problem?) Look.red('Not valid: $problem'),
  if (file.draft.changed) Look.yellow('Unsaved changes.'),
];

MenuEntry _reviewEntry(ConfigFileScreen file) => MenuEntry(
  'Review and save',
  detail: file.draft.changed ? 'see the changes, then save' : 'no changes',
  onSelect: (navigator) => _push(navigator, file.review()),
);

Cmd? _push(Navigator navigator, Screen screen) {
  navigator.push(screen);
  return null;
}

/// A [PromptScreen] whose [onSubmit] edits the draft and returns what to
/// say; an [InvalidInputException] ends up in the status line.
Cmd? _prompt(
  Navigator navigator,
  String title,
  String label, {
  String initial = '',
  List<String> help = const [],
  required String Function(String text) onSubmit,
}) => _push(
  navigator,
  PromptScreen(
    title,
    label,
    initial: initial,
    help: help,
    onSubmit: (text, navigator) {
      navigator.say(onSubmit(text));
      return null;
    },
  ),
);

int _number(String text) =>
    int.tryParse(text.trim()) ?? (throw InvalidInputException('"${text.trim()}" is not a whole number.'));

/// A menu of [options] (the current one marked); choosing one calls
/// [onPick] and goes back.
Screen _choice(
  String title,
  List<(String, String?)> options, {
  String? current,
  required String Function(int) onPick,
}) => MenuScreen(
  title,
  entries: () => [
    for (final (i, (label, detail)) in options.indexed)
      MenuEntry(
        label == current ? '$label  ✓' : label,
        detail: detail,
        onSelect: (navigator) {
          navigator
            ..pop()
            ..say(onPick(i));
          return null;
        },
      ),
  ],
);

/// The entries of [list], each opening its own menu, and *Add …*.
Screen _listScreen(ConfigFileScreen file, WorkflowList list) {
  WorkflowSettings settings() => WorkflowSettings(file.draft);
  return MenuScreen(
    _label(list),
    intro: () => [
      ..._problem(file),
      switch (list) {
        WorkflowList.statuses => 'The board columns in order; claim moves items to the first active status.',
        WorkflowList.priorities => 'From the most urgent.',
        WorkflowList.types => 'Labels of items; the hierarchy comes from parent, not from the type.',
        WorkflowList.milestones => 'Versions in order; ready work goes by milestone first, later is the pile.',
      },
      if (settings().isBuiltIn(list) && list != WorkflowList.milestones)
        Look.dim('Built in: the first change writes the list into backlog.yaml.'),
    ],
    entries: () {
      final s = settings();
      final entries = s.entries(list);
      final standard = s.effectiveDefault(list);
      return [
        for (final (i, entry) in entries.indexed)
          MenuEntry(
            entry.id,
            detail: _entryDetail(list, entry, isDefault: list.hasDefault && entry.id == standard),
            onSelect: (navigator) => _push(navigator, _EntryScreen(file, list, i)),
          ),
        MenuEntry(
          'Add a ${list.singular}…',
          onSelect: (navigator) => _prompt(
            navigator,
            'New ${list.singular}',
            'Id of the new ${list.singular}:',
            help: [if (list == WorkflowList.statuses) 'Then choose its category.'],
            onSubmit: (text) {
              final id = text.trim();
              if (list != WorkflowList.statuses) {
                settings().add(list, id);
                return 'Added ${list.singular} $id (not saved yet).';
              }
              // Checked before the category is asked for.
              if (settings().ids(list).contains(id)) {
                throw InvalidInputException('There is a status "$id" already.');
              }
              navigator.push(
                _choice(
                  'Category of $id',
                  _categories,
                  onPick: (i) {
                    settings().add(list, id, category: StatusCategory.values[i]);
                    return 'Added status $id (not saved yet).';
                  },
                ),
              );
              return 'Choose the category of $id.';
            },
          ),
        ),
        _reviewEntry(file),
      ];
    },
  );
}

const _categories = [
  ('open', 'not started (backlog, todo, …)'),
  ('active', 'being worked on (in-progress, review, …)'),
  ('done', 'finished or dropped; satisfies dependencies'),
];

String _entryDetail(WorkflowList list, WorkflowEntry entry, {required bool isDefault}) => [
  if (list == WorkflowList.statuses) entry.category ?? Look.red('no category'),
  if (entry.pickable) 'pickable',
  ?entry.title,
  if (entry.due case final due?) 'due $due',
  if (isDefault) 'default',
].join(' · ');

/// The menu of one entry of a list: rename, the status's category and
/// pickable, the milestone's title and due date, move, make default,
/// remove. Follows its entry when it moves.
final class _EntryScreen extends MenuScreen {
  _EntryScreen(this.file, this.list, this.index) : super('');

  final ConfigFileScreen file;
  final WorkflowList list;
  int index;

  WorkflowSettings get _settings => WorkflowSettings(file.draft);

  WorkflowEntry? get _entry {
    final entries = _settings.entries(list);
    return index < entries.length ? entries[index] : null;
  }

  @override
  String get title => _entry?.id ?? '?';

  @override
  List<String> get intro => _problem(file);

  @override
  List<MenuEntry> get entries {
    final entry = _entry;
    if (entry == null) return const [];
    final count = _settings.entries(list).length;
    final id = entry.id;
    return [
      MenuEntry(
        'Rename…',
        detail: switch (list) {
          WorkflowList.statuses => 'also the default, its colour and the actions; items keep the old status',
          WorkflowList.milestones => 'items keep the old milestone',
          _ => 'also the default and its colour; items keep the old ${list.singular}',
        },
        onSelect: (navigator) => _prompt(
          navigator,
          'Rename $id',
          'New id of ${list.singular} $id:',
          initial: id,
          help: const ['backlog lint lists the items that still use the old one.'],
          onSubmit: (text) {
            _settings.rename(list, index, text.trim());
            return 'Renamed $id to ${text.trim()} (not saved yet).';
          },
        ),
      ),
      if (list == WorkflowList.statuses) ...[
        MenuEntry(
          'Category',
          detail: entry.category ?? 'none',
          onSelect: (navigator) => _push(
            navigator,
            _choice(
              'Category of $id',
              _categories,
              current: entry.category,
              onPick: (i) {
                _settings.setCategory(index, StatusCategory.values[i]);
                return '$id is ${StatusCategory.values[i].name} (not saved yet).';
              },
            ),
          ),
        ),
        MenuEntry(
          'Pickable',
          detail: entry.pickable
              ? 'yes: agents take ready work from it (Enter: no)'
              : 'no (Enter: yes, agents take ready work from it)',
          onSelect: (navigator) {
            _settings.setPickable(index, !entry.pickable);
            navigator.say('$id is ${entry.pickable ? 'not ' : ''}pickable (not saved yet).');
            return null;
          },
        ),
      ],
      if (list == WorkflowList.milestones) ...[
        MenuEntry(
          'Title…',
          detail: entry.title ?? 'none',
          onSelect: (navigator) => _prompt(
            navigator,
            'Title of $id',
            'Title (empty removes it):',
            initial: entry.title ?? '',
            onSubmit: (text) {
              _settings.setMilestone(index, title: text);
              return 'Title of $id set (not saved yet).';
            },
          ),
        ),
        MenuEntry(
          'Due date…',
          detail: entry.due ?? 'none',
          onSelect: (navigator) => _prompt(
            navigator,
            'Due date of $id',
            'Due date, e.g. 2026-12-31 (empty removes it):',
            initial: entry.due ?? '',
            onSubmit: (text) {
              _settings.setMilestone(index, due: text);
              return 'Due date of $id set (not saved yet).';
            },
          ),
        ),
      ],
      MenuEntry(
        'Move up',
        detail: 'position ${index + 1} of $count',
        enabled: index > 0,
        onSelect: (n) => _move(n, -1),
      ),
      MenuEntry(
        'Move down',
        detail: 'position ${index + 1} of $count',
        enabled: index < count - 1,
        onSelect: (n) => _move(n, 1),
      ),
      if (list.hasDefault)
        MenuEntry(
          'Make default',
          detail: _settings.effectiveDefault(list) == id ? 'it is the default' : 'new items get it',
          onSelect: (navigator) {
            _settings.setDefault(list, id);
            navigator.say('New items get ${list.singular} $id (not saved yet).');
            return null;
          },
        ),
      MenuEntry(
        'Remove',
        detail: 'references to it stay; the review says whether the file is still valid',
        onSelect: (navigator) => _push(
          navigator,
          ConfirmScreen(
            'Remove $id',
            'Remove ${list.singular} $id? (y: remove, n: keep)',
            onYes: (navigator) {
              _settings.remove(list, index);
              navigator
                ..pop()
                ..say('Removed ${list.singular} $id (not saved yet).');
            },
          ),
        ),
      ),
    ];
  }

  Cmd? _move(Navigator navigator, int by) {
    _settings.move(list, index, index + by);
    index += by;
    navigator.say('Moved $title to position ${index + 1} (not saved yet).');
    return null;
  }
}

/// The defaults of new items: status, priority, type; each from its list
/// or the built-in rule.
Screen _defaultsScreen(ConfigFileScreen file) {
  WorkflowSettings settings() => WorkflowSettings(file.draft);
  return MenuScreen(
    'Defaults',
    intro: () => [..._problem(file), 'What new items get when nothing else is given.'],
    entries: () => [
      for (final list in WorkflowList.values)
        if (list.hasDefault)
          MenuEntry(
            '${list.singular[0].toUpperCase()}${list.singular.substring(1)}',
            detail:
                '${settings().effectiveDefault(list) ?? '–'}'
                '${settings().writtenDefault(list) == null ? '  (by the built-in rule)' : ''}',
            onSelect: (navigator) {
              final ids = settings().ids(list);
              return _push(
                navigator,
                _choice(
                  'Default ${list.singular}',
                  [
                    for (final id in ids) (id, null),
                    (
                      'Built-in rule',
                      list == WorkflowList.priorities ? 'the middle priority' : 'the first ${list.singular}',
                    ),
                  ],
                  current: settings().writtenDefault(list),
                  onPick: (i) {
                    settings().setDefault(list, i < ids.length ? ids[i] : null);
                    return 'Default ${list.singular}: ${settings().effectiveDefault(list)} (not saved yet).';
                  },
                ),
              );
            },
          ),
      _reviewEntry(file),
    ],
  );
}
