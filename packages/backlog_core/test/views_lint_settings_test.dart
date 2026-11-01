import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ViewSettings', () {
    const view = '''
name: Board   # the main one
layout: kanban
filter: {type: {not: [epic]}}
group_by: status
''';

    test('reads and edits the keys of a view, keeping comments', () {
      final settings = ViewSettings(ConfigDraft(view));
      expect(settings.layout, ViewLayout.kanban);
      expect(settings.text('filter'), '{"type":{"not":["epic"]}}');
      settings
        ..setText('section', 'Milestones')
        ..setLayout(ViewLayout.table)
        ..setList('columns', 'todo, in-progress, done')
        ..setList('sort', 'priority, -updated')
        ..setFilter('{milestone: v0.3, category: {not: [done]}}')
        ..setPinned(true);
      expect(settings.draft.text, contains('name: Board   # the main one'));
      expect(settings.text('columns'), 'todo, in-progress, done');
      final parsed = parseViewYaml('board', settings.draft.text);
      expect(parsed.section, 'Milestones');
      expect(parsed.layout, ViewLayout.table);
      expect(parsed.columns, ['todo', 'in-progress', 'done']);
      expect(parsed.sort.map((k) => '$k'), ['priority', '-updated']);
      expect(parsed.pinned, isTrue);
      expect(settings.draft.valueAt(['filter', 'milestone']), 'v0.3');

      settings
        ..setText('section', '')
        ..setList('columns', '')
        ..setFilter(' ')
        ..setPinned(false);
      expect(settings.text('section'), isNull);
      expect(settings.text('columns'), isNull);
      expect(settings.text('filter'), isNull);
      expect(() => settings.setList('columns', 'a, a'), throwsA(isA<InvalidInputException>()));
      expect(() => settings.setList('sort', 'priority desc'), throwsA(isA<InvalidInputException>()));
      expect(() => settings.setFilter('todo'), throwsA(isA<InvalidInputException>()));
      expect(() => settings.setText('layout', 'x'), throwsA(isA<InvalidInputException>()));
    });

    test('the editor of a view: existing files, new ids, validation', () async {
      final (backlog, _) = await tempBacklog();
      expect(await viewIds(backlog.root), containsAll(['board', 'ready']));
      final editor = viewConfigEditor(backlog.root, 'board');
      expect(editor.location, p.join(backlog.root, 'views', 'board.yaml'));
      final draft = await editor.open();
      draft.set(['layout'], 'wall');
      expect(editor.problem(draft), contains('Unknown layout "wall"'));

      final fresh = viewConfigEditor(backlog.root, 'v03');
      final created = (await fresh.open())..set(['name'], 'v0.3');
      ViewSettings(created).setLayout(ViewLayout.kanban);
      await fresh.save(created);
      expect(await viewIds(backlog.root), contains('v03'));
      expect(() => viewConfigEditor(backlog.root, '../x'), throwsA(isA<InvalidInputException>()));
    });
  });

  test('lint fixes: unknown values, missing references, claims', () async {
    final (backlog, clock) = await tempBacklog();
    final a = await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    final b = await backlog.items.create(NewItem(title: 'B', status: 'todo', dependsOn: [a.id.value]));
    final c = await backlog.items.create(const NewItem(title: 'C', status: 'todo'));
    await backlog.claims.claim(a.id.value, 'w1');
    await backlog.claims.claim(c.id.value, 'w2');
    clock.advance(const Duration(days: 1));
    final bFile = File((await backlog.items.locationOf(b.id))!);
    bFile.writeAsStringSync(bFile.readAsStringSync().replaceFirst('status: todo', 'status: doing'));
    File((await backlog.items.locationOf(a.id))!).deleteSync();

    final fixer = backlog.lintFixer;
    final issues = await backlog.linter.run();
    LintIssue find(String code, String item) => issues.firstWhere((i) => i.code == code && i.item == item);

    final status = find('unknown-status', '${b.id}');
    expect(status.value, 'doing');
    final statusFixes = fixer.fixes(status);
    expect(statusFixes.map((f) => f.label), contains('Set status to in-progress'));
    await statusFixes.firstWhere((f) => f.label == 'Set status to in-progress').apply();

    final dangling = find('dangling-reference', '${b.id}');
    expect((dangling.field, dangling.value), ('depends_on', '${a.id}'));
    await fixer.fixes(dangling).single.apply();

    await fixer.fixes(find('orphan-claim', '${a.id}')).single.apply();
    final expired = fixer.fixes(find('expired-claim', '${c.id}')).single;
    expect(expired.label, startsWith('Release ${c.id}'));
    await expired.apply();
    expect(fixer.fixes(const LintIssue(Severity.error, 'duplicate-id', 'x', item: 'T-1')), isEmpty);

    final after = await backlog.linter.run();
    expect(after.where((i) => i.severity == Severity.error), isEmpty, reason: '$after');
    expect(after.where((i) => i.code.endsWith('-claim')), isEmpty, reason: '$after');
    expect((await backlog.items.get(b.id.value)).dependsOn, isEmpty);
    expect((await backlog.items.get(c.id.value)).status, 'todo');
  });
}
