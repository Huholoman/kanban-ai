import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File config;
  late FileWorkflowSource source;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('workflow_source_');
    config = File(p.join(dir.path, 'backlog.yaml'));
    source = FileWorkflowSource(BacklogLayout(dir.path));
  });
  tearDown(() => dir.delete(recursive: true));

  Future<WorkflowRevision> put(List<Object> path, Object value, {WorkflowRevision? expected}) =>
      source.edit([WorkflowEdit.set(path, value)], expected: expected);
  Future<Workflow> workflow() async => (await source.load()).workflow;

  group('FileWorkflowSource', () {
    test('a missing file has no revision and does not load', () async {
      expect(await source.revision(), isNull);
      await expectLater(source.load, throwsA(isA<NotFoundException>()));
      await expectLater(() => put(['id', 'prefix'], 'X'), throwsA(isA<NotFoundException>()));
    });

    test('load parses the workflow; the revision follows the content', () async {
      await config.writeAsString('id: {prefix: KA}\n');
      final loaded = await source.load();
      expect(loaded.workflow.idPrefix, 'KA');
      expect(await source.revision(), loaded.revision);

      await config.writeAsString('id: {prefix: KB}\n');
      expect(await source.revision(), isNot(loaded.revision));
      await config.writeAsString('id: {prefix: KA}\n');
      expect(await source.revision(), loaded.revision);
    });

    test('edits keep comments, key order and unknown keys', () async {
      await config.writeAsString('''
# My backlog.
id:
  prefix: T      # short ids
  length: 4
custom: kept
claims:
  lease_minutes: 60
''');
      final revision = await source.edit(const [
        WorkflowEdit.set(['id', 'prefix'], 'KA'),
        WorkflowEdit.set(['defaults', 'priority'], 'p1'),
        WorkflowEdit.remove(['claims', 'lease_minutes']),
        WorkflowEdit.remove(['not', 'there']),
      ]);
      final text = config.readAsStringSync();
      expect(text, startsWith('# My backlog.\nid:\n  prefix: KA      # short ids\n  length: 4\ncustom: kept\n'));
      expect(text, contains('defaults:\n  priority: p1'));
      expect(text, isNot(contains('lease_minutes')));
      expect(await source.revision(), revision);
      expect((await workflow()).idPrefix, 'KA');
      expect((await workflow()).defaultPriority, 'p1');
    });

    test('edits reach into lists and append to them', () async {
      await config.writeAsString('milestones:\n  - id: v1\n    title: First\n');
      await put(['milestones', 0, 'due'], '2026-12-01');
      await put(['milestones', 1], {'id': 'v2'});
      expect((await workflow()).milestones.map((m) => (m.id, m.due)), [('v1', '2026-12-01'), ('v2', null)]);
      await expectLater(() => put(['milestones', 5, 'id'], 'v6'), throwsA(isA<InvalidInputException>()));
    });

    test('an empty file or one with comments only gets the setting below them', () async {
      await config.writeAsString('# nothing yet\n');
      await put(['id', 'prefix'], 'KA');
      expect(config.readAsStringSync(), startsWith('# nothing yet\n'));
      expect((await workflow()).idPrefix, 'KA');
    });

    test('an empty value becomes the mapping that is needed', () async {
      await config.writeAsString('appearance:\n');
      await put(['appearance', 'mode'], 'dark');
      expect((await workflow()).appearance.mode, 'dark');
    });

    test('nothing is written when the result is invalid or the file changed', () async {
      const original = 'claims:\n  lease_minutes: 60\n';
      await config.writeAsString(original);
      final read = (await source.load()).revision;
      await expectLater(() => put(['claims', 'lease_minutes'], 'soon'), throwsA(isA<ConfigurationException>()));
      await expectLater(() => put(['claims', 'lease_minutes', 'x'], 1), throwsA(isA<InvalidInputException>()));
      expect(config.readAsStringSync(), original);

      await config.writeAsString('claims:\n  lease_minutes: 90\n');
      final stale = put(['claims', 'lease_minutes'], 30, expected: read);
      await expectLater(stale, throwsA(isA<UnavailableException>()));
      expect(config.readAsStringSync(), contains('90'));
      await put(['claims', 'lease_minutes'], 30, expected: (await source.load()).revision);
      expect((await workflow()).claimLease, const Duration(minutes: 30));
    });
  });

  test('an opened backlog knows when its configuration went stale', () async {
    await Backlog.init(dir.path);
    final backlog = await Backlog.open(dir.path);
    expect(await backlog.isStale, isFalse);
    await backlog.configuration.edit(const [
      WorkflowEdit.set(['id', 'prefix'], 'KA'),
    ]);
    expect(await backlog.isStale, isTrue);
    expect(backlog.workflow.idPrefix, 'T');
    expect((await Backlog.open(dir.path)).workflow.idPrefix, 'KA');
  });
}
