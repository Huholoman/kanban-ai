import 'package:backlog_core/backlog_core.dart'
    show
        Backlog,
        Claim,
        ConfigDraft,
        ConfigEditor,
        InvalidInputException,
        LintFix,
        LintIssue,
        Severity,
        ViewLayout,
        ViewSettings,
        viewConfigEditor,
        viewIds;
import 'package:dart_tui/dart_tui.dart' show Cmd;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Views*: the views of the backlog [root], each edited as its own draft
/// (`views/<id>.yaml`), and *Add a view…*.
Cmd openViews(String root) => Navigator.task(() async {
  final screens = <String, ConfigFileScreen>{};
  for (final id in await viewIds(root)) {
    final editor = viewConfigEditor(root, id);
    screens[id] = _viewScreen(id, editor, await editor.open());
  }
  return (navigator) => navigator.push(_ViewsScreen(root, screens));
});

final class _ViewsScreen extends MenuScreen {
  _ViewsScreen(this.root, this.screens) : super('Views');

  final String root;
  final Map<String, ConfigFileScreen> screens;

  @override
  List<String> get intro => const ['Saved views of the board (views/<id>.yaml); each is saved on its own.'];

  @override
  List<MenuEntry> get entries => [
    for (final MapEntry(key: id, value: screen) in screens.entries)
      MenuEntry(
        id,
        detail: _summary(screen),
        onSelect: (navigator) {
          navigator.push(screen);
          return null;
        },
      ),
    MenuEntry(
      'Add a view…',
      detail: 'a new views/<id>.yaml, written by its Review and save',
      onSelect: (navigator) {
        navigator.push(
          PromptScreen(
            'Add a view',
            'Id of the new view (lower-case letters, digits, - and _):',
            onSubmit: (text, navigator) {
              final id = text.trim();
              if (screens.containsKey(id)) throw InvalidInputException('There is a view "$id" already.');
              final editor = viewConfigEditor(root, id);
              return Navigator.task(() async {
                final draft = await editor.open();
                ViewSettings(draft)
                  ..setText('name', id)
                  ..setLayout(ViewLayout.kanban);
                draft.set(['group_by'], 'status');
                final screen = screens[id] = _viewScreen(id, editor, draft);
                return (navigator) => navigator
                  ..push(screen)
                  ..say('New view $id (not saved yet).');
              });
            },
          ),
        );
        return null;
      },
    ),
  ];

  static String _summary(ConfigFileScreen screen) {
    final settings = ViewSettings(screen.draft);
    final problem = screen.editor.problem(screen.draft);
    return [
      settings.text('name') ?? '',
      settings.layout.name,
      ?settings.text('section'),
      if (settings.pinned) 'pinned',
      if (screen.draft.changed) Look.yellow('unsaved'),
      if (problem != null) Look.red(problem),
    ].join(' · ');
  }
}

ConfigFileScreen _viewScreen(String id, ConfigEditor editor, ConfigDraft draft) => ConfigFileScreen(
  id,
  editor,
  draft,
  sections: (screen) {
    ViewSettings settings() => ViewSettings(screen.draft);
    MenuEntry text(String label, String key, String question, {String? help}) => MenuEntry(
      label,
      detail: settings().text(key) ?? 'none',
      onSelect: (navigator) {
        navigator.push(
          PromptScreen(
            label,
            question,
            initial: settings().text(key) ?? '',
            help: [?help, 'Empty removes it.'],
            onSubmit: (value, navigator) {
              if (ViewSettings.listKeys.contains(key)) {
                settings().setList(key, value);
              } else if (key == 'filter') {
                settings().setFilter(value);
              } else {
                settings().setText(key, value);
              }
              navigator.say('$label of $id set (not saved yet).');
              return null;
            },
          ),
        );
        return null;
      },
    );
    return [
      text('Name', 'name', 'Name in the list of views:'),
      text('Section', 'section', 'Heading in the list of views:'),
      MenuEntry(
        'Layout',
        detail: settings().layout.name,
        onSelect: (navigator) {
          navigator.push(
            MenuScreen(
              'Layout of $id',
              entries: () => [
                for (final layout in ViewLayout.values)
                  MenuEntry(
                    layout == settings().layout ? '${layout.name}  ✓' : layout.name,
                    onSelect: (navigator) {
                      settings().setLayout(layout);
                      navigator
                        ..pop()
                        ..say('Layout of $id: ${layout.name} (not saved yet).');
                      return null;
                    },
                  ),
              ],
            ),
          );
          return null;
        },
      ),
      text('Group by', 'group_by', 'Field to group by (status, priority, milestone, labels, …):'),
      text(
        'Columns',
        'columns',
        'Groups shown and their order, comma-separated:',
        help: 'e.g. todo, in-progress, done',
      ),
      text('Sort', 'sort', 'Sort keys, comma-separated; - sorts descending:', help: 'e.g. priority, -updated'),
      text('Fields', 'fields', 'Extra fields on cards and in tables, comma-separated:'),
      text(
        'Filter',
        'filter',
        'Filter as a YAML mapping:',
        help: 'e.g. {milestone: v0.3, category: {not: [done]}} or {or: [{priority: p0}, {labels: security}]}',
      ),
      MenuEntry(
        'Pinned',
        detail: settings().pinned ? 'yes: on the bottom bar of phones (Enter: no)' : 'no (Enter: yes)',
        onSelect: (navigator) {
          settings().setPinned(!settings().pinned);
          navigator.say('$id is ${settings().pinned ? '' : 'not '}pinned (not saved yet).');
          return null;
        },
      ),
    ];
  },
  notes: [Look.dim('Filters: field: value, field: [a, b], {not: …}, {in: …}, {exists: …}, {contains: …}, and/or/not.')],
);

/// *Claims*: who holds which item, live or expired; releasing one acts at
/// once (no review).
Cmd openClaims(String root) => Navigator.task(() async {
  final backlog = await Backlog.open(root);
  final screen = _ClaimsScreen(backlog);
  await screen.reload();
  return (navigator) => navigator.push(screen);
});

final class _ClaimsScreen extends MenuScreen {
  _ClaimsScreen(this.backlog) : super('Claims');

  final Backlog backlog;
  List<Claim> _claims = const [];
  Map<String, String> _titles = const {};

  Future<void> reload() async {
    _claims = await backlog.claims.all();
    _titles = {for (final item in await backlog.items.all()) item.id.value: item.title};
  }

  @override
  List<String> get intro => [
    _claims.isEmpty ? 'Nobody holds an item.' : 'Who works on what. Releasing acts at once, without a review.',
  ];

  @override
  List<MenuEntry> get entries {
    final now = DateTime.now();
    return [
      for (final claim in _claims)
        MenuEntry(
          '${claim.itemId}  ${claim.agent}',
          detail: [
            _titles[claim.itemId.value] ?? Look.red('no such item'),
            claim.isExpiredAt(now)
                ? Look.yellow('expired ${_ago(now.difference(claim.expiresAt))} ago')
                : 'live for ${_ago(claim.expiresAt.difference(now))}',
          ].join(' · '),
          onSelect: (navigator) {
            final id = '${claim.itemId}';
            final exists = _titles.containsKey(id);
            navigator.push(
              MenuScreen(
                'Release $id',
                intro: () => [
                  exists
                      ? 'Release $id held by ${claim.agent}? An active item goes back to '
                            '${backlog.workflow.pickableStatus}.'
                      : 'Remove the lock of $id, an item that does not exist?',
                ],
                entries: () => [
                  MenuEntry(exists ? 'Release' : 'Remove the lock', onSelect: (_) => _release(claim, exists)),
                  MenuEntry(
                    'Keep',
                    onSelect: (navigator) {
                      navigator.pop();
                      return null;
                    },
                  ),
                ],
              ),
            );
            return null;
          },
        ),
    ];
  }

  Cmd _release(Claim claim, bool exists) => Navigator.task(() async {
    if (exists) {
      await backlog.claims.release('${claim.itemId}', force: true);
    } else {
      await backlog.claims.removeLock(claim.itemId);
    }
    await reload();
    return (navigator) => navigator
      ..pop()
      ..say('Released ${claim.itemId}.');
  });

  static String _ago(Duration duration) => duration.inHours >= 1
      ? '${duration.inHours} h ${duration.inMinutes % 60} min'
      : '${duration.inMinutes.clamp(0, 59)} min';
}

/// *Lint*: the issues of the backlog; an issue with fixes offers them,
/// and a fix acts at once, then lint runs again.
Cmd openLint(String root) => Navigator.task(() async {
  final backlog = await Backlog.open(root);
  final screen = _LintScreen(backlog, await backlog.linter.run());
  return (navigator) => navigator.push(screen);
});

final class _LintScreen extends MenuScreen {
  _LintScreen(this.backlog, this.issues) : super('Lint');

  final Backlog backlog;
  List<LintIssue> issues;

  @override
  List<String> get intro => [
    if (issues.isEmpty) Look.green('No problems found.'),
    if (issues.isNotEmpty)
      '${issues.where((i) => i.severity == Severity.error).length} errors, '
          '${issues.where((i) => i.severity == Severity.warning).length} warnings. '
          'Fixes act at once, without a review.',
  ];

  @override
  List<MenuEntry> get entries => [
    for (final issue in issues)
      MenuEntry(
        '${issue.severity == Severity.error ? Look.red('✗') : Look.yellow('!')} ${issue.code}${issue.item == null ? '' : '  ${issue.item}'}',
        detail: issue.message,
        onSelect: (navigator) {
          final fixes = backlog.lintFixer.fixes(issue);
          if (fixes.isEmpty) {
            navigator.say('No fix offered for ${issue.code}; fix it by hand.', error: true);
            return null;
          }
          navigator.push(
            MenuScreen(
              'Fix ${issue.item ?? issue.code}',
              intro: () => [issue.message],
              entries: () => [for (final fix in fixes) MenuEntry(fix.label, onSelect: (_) => _apply(fix))],
            ),
          );
          return null;
        },
      ),
  ];

  Cmd _apply(LintFix fix) => Navigator.task(() async {
    await fix.apply();
    final again = await backlog.linter.run();
    return (navigator) {
      issues = again;
      navigator
        ..pop()
        ..say('${fix.label}: done.');
    };
  });
}
