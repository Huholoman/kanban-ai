import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _config = '''
# Backlog configuration.
id:
  prefix: HB   # ids like HB-7f3a
  length: 4

claims:
  lease_minutes: 240   # a claim without heartbeat expires after this
custom_key: kept
''';

void main() {
  group('diff', () {
    test('marks removed and added lines, removals first', () {
      expect(diffLines('a\nb\nc\n', 'a\nx\nc\n').map((l) => l.marked), [' a', '-b', '+x', ' c']);
      expect(diffLines('', 'a\n').map((l) => l.marked), ['+a']);
      expect(diffLines('a\n', 'a\n').map((l) => l.marked), [' a']);
    });

    test('hunks keep only the context around changes', () {
      final before = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
      final after = before.replaceFirst('line 10', 'line ten');
      expect(diffHunks(before, after, context: 1).map((l) => l.marked), [
        '… 8 unchanged lines',
        ' line 9',
        '-line 10',
        '+line ten',
        ' line 11',
        '… 9 unchanged lines',
      ]);
      expect(diffHunks(before, before), isEmpty);
    });
  });

  group('ConfigDraft', () {
    test('sets values keeping comments, order and unknown keys', () {
      final draft = ConfigDraft(_config)..set(['claims', 'lease_minutes'], 60);
      expect(draft.changed, isTrue);
      expect(draft.text, contains('# Backlog configuration.'));
      expect(draft.text, contains('prefix: HB   # ids like HB-7f3a'));
      expect(draft.text, contains('custom_key: kept'));
      expect(draft.valueAt(['claims', 'lease_minutes']), 60);
      expect(draft.diff.where((l) => l.kind != DiffKind.same && l.kind != DiffKind.skipped).map((l) => l.marked), [
        '-  lease_minutes: 240   # a claim without heartbeat expires after this',
        '+  lease_minutes: 60   # a claim without heartbeat expires after this',
      ]);
    });

    test('creates missing maps, replaces scalars on the way and appends to lists', () {
      final draft = ConfigDraft(_config)
        ..set(['appearance', 'light', 'seed'], '#3f51b5')
        ..set(['custom_key', 'nested'], true)
        ..set(['types'], ['task'])
        ..set(['types', 1], 'bug');
      expect(draft.valueAt(['appearance']), {
        'light': {'seed': '#3f51b5'},
      });
      expect(draft.valueAt(['custom_key']), {'nested': true});
      expect(draft.valueAt(['types']), ['task', 'bug']);
      expect(() => draft.set(['types', 5], 'x'), throwsA(isA<InvalidInputException>()));
    });

    test('works on an empty file and removes keys', () {
      final draft = ConfigDraft('')..set(['claims', 'lease_minutes'], 30);
      expect(draft.valueAt(['claims', 'lease_minutes']), 30);
      expect(draft.remove(['claims', 'lease_minutes']), isTrue);
      expect(draft.remove(['nothing']), isFalse);
      expect(draft.valueAt(['claims', 'lease_minutes']), isNull);
      draft.reset();
      expect(draft.text, '');
    });

    test('typed values read as YAML and print back', () {
      expect(parseConfigValue('30'), 30);
      expect(parseConfigValue(' true '), true);
      expect(parseConfigValue('[a, b]'), ['a', 'b']);
      expect(parseConfigValue('{a: 1}'), {'a': 1});
      expect(parseConfigValue('#3f51b5'), '#3f51b5');
      expect(parseConfigValue('null'), isNull);
      expect(() => parseConfigValue('[a'), throwsA(isA<InvalidInputException>()));
      expect(formatConfigValue('#3f51b5'), '#3f51b5');
      expect(formatConfigValue('30'), '"30"');
      expect(formatConfigValue(30), '30');
      expect(formatConfigValue(['a', 1]), '["a",1]');
      expect(formatConfigValue(null), '');
    });

    test('paths parse and print', () {
      expect(parseConfigPath('claims.lease_minutes'), ['claims', 'lease_minutes']);
      expect(parseConfigPath('statuses[1].id'), ['statuses', 1, 'id']);
      expect(parseConfigPath('statuses.1.id'), ['statuses', 1, 'id']);
      expect(formatConfigPath(['statuses', 1, 'id']), 'statuses[1].id');
      expect(() => parseConfigPath(''), throwsA(isA<InvalidInputException>()));
      expect(() => parseConfigPath('a..b'), throwsA(isA<InvalidInputException>()));
    });
  });

  group('ConfigEditor', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('settings_'));
    tearDown(() => dir.delete(recursive: true));

    test('validates, saves and refuses a file changed meanwhile', () async {
      final file = File(p.join(dir.path, BacklogLayout.configFileName))..writeAsStringSync(_config);
      final editor = projectConfigEditor(dir.path);
      expect(editor.scope, ConfigScope.project);

      final draft = await editor.open();
      draft.set(['claims', 'lease_minutes'], 'soon');
      expect(editor.problem(draft), contains('lease_minutes must be an integer'));
      await expectLater(editor.save(draft), throwsA(isA<ConfigurationException>()));
      expect(file.readAsStringSync(), _config);

      draft.set(['claims', 'lease_minutes'], 90);
      expect(editor.problem(draft), isNull);
      final saved = await editor.save(draft);
      expect(saved.changed, isFalse);
      expect(file.readAsStringSync(), contains('lease_minutes: 90   # a claim'));

      final stale = await editor.open();
      file.writeAsStringSync('${file.readAsStringSync()}# edited by hand\n');
      stale.set(['id', 'length'], 6);
      await expectLater(editor.save(stale), throwsA(isA<UnavailableException>()));
      expect(file.readAsStringSync(), endsWith('# edited by hand\n'));
    });

    test('the registry editor starts from a missing file', () async {
      final location = p.join(dir.path, 'kanban-ai', 'projects.yaml');
      final editor = registryConfigEditor(location);
      final draft = await editor.open();
      expect(draft.text, '');
      draft.set(
        ['projects'],
        [
          {'path': 'a'},
          {'path': 'b', 'id': 'a'},
        ],
      );
      expect(editor.problem(draft), contains('used twice'));
      draft.set(['projects', 1, 'id'], 'b');
      await editor.save(draft);
      expect((await YamlProjectRegistryStore(location).load()).entries.map((e) => e.id), ['a', 'b']);
    });
  });
}
