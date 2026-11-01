import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

const _registry = '''
# Backlogs served by backlog-server
projects:
  - id: kanban
    path: ~/p/kanban-ai/backlog   # the tool itself
    pinned: true
  - path: ../hobbyo/backlog
custom: kept
''';

RegistrySettings _settings([String text = _registry]) =>
    RegistrySettings(ConfigDraft(text), baseDir: '/home/me/.config/kanban-ai', home: '/home/me');

List<String> _ids(RegistrySettings settings) => [
  for (final entry in parseProjectRegistryYaml(
    settings.draft.text,
    baseDir: settings.baseDir,
    home: settings.home,
  ).entries)
    entry.id,
];

void main() {
  test('reads the entries leniently, ids derived where missing', () {
    final entries = _settings().entries;
    expect(entries.map((e) => (e.id, e.idWritten, e.path, e.pinned)), [
      ('kanban', true, '/home/me/p/kanban-ai/backlog', true),
      ('hobbyo', false, '/home/me/.config/hobbyo/backlog', false),
    ]);
    expect(entries.first.displayName, 'kanban-ai');
    expect(_settings('').entries, isEmpty);
  });

  test('adds a folder with a unique id, written under ~', () {
    final settings = _settings();
    expect(settings.add('/home/me/x/hobbyo/backlog'), 'hobbyo-2');
    expect(settings.draft.text, contains('path: ~/x/hobbyo/backlog'));
    expect(_ids(settings), ['kanban', 'hobbyo', 'hobbyo-2']);
    expect(() => settings.add('~/p/kanban-ai/backlog'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.add(' '), throwsA(isA<InvalidInputException>()));

    final empty = _settings('');
    expect(empty.add('/srv/notes'), 'notes');
    expect(_ids(empty), ['notes']);
  });

  test('reorders, renames, pins and removes, keeping comments', () {
    final settings = _settings()
      ..move(1, 0)
      ..setId(0, 'hobby')
      ..setName(0, 'Hobby')
      ..setPinned(0, true)
      ..setPinned(1, false);
    expect(_ids(settings), ['hobby', 'kanban']);
    final entries = settings.entries;
    expect(entries.map((e) => (e.displayName, e.pinned)), [('Hobby', true), ('kanban-ai', false)]);
    expect(settings.draft.text, contains('# the tool itself'));
    expect(settings.draft.text, contains('custom: kept'));
    settings.setName(0, '');
    expect(settings.entries.first.name, isNull);
    expect(() => settings.setId(0, 'Kanban AI'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setId(0, 'kanban'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.move(1, 2), throwsA(isA<InvalidInputException>()));
    settings.remove(0);
    expect(_ids(settings), ['kanban']);
    expect(() => settings.remove(3), throwsA(isA<InvalidInputException>()));
  });
}
