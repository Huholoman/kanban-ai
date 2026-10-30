import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
import 'package:backlog_app/features/item/application/detail_navigation.dart';
import 'package:backlog_app/features/item/application/item_body.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

/// An epic with three stories; the second story has two tasks and depends
/// on the first one.
List<ItemDto> _tree() => [
  item('E-1', type: 'epic'),
  item('S-1', type: 'story', parent: 'E-1', status: 'done'),
  item('S-2', type: 'story', parent: 'E-1', dependsOn: ['S-1'], body: '## Plan\nTime the restore.\n- [ ] script\n'),
  item('S-3', type: 'story', parent: 'E-1'),
  item('T-1', parent: 'S-2', body: 'Record restore time into the runbook.', status: 'done'),
  item('T-2', parent: 'S-2'),
  item('T-3', parent: 'T-1'),
];

Future<FakeBacklogApi> _pumpDetail(WidgetTester tester, String reference, {List<ItemDto>? items}) async {
  tester.view.physicalSize = const Size(560, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = FakeBacklogApi(items ?? _tree());
  await tester.pumpWidget(
    AppScope(
      api: api,
      child: MaterialApp(
        theme: BoardTokens.light.toTheme(Brightness.light),
        home: Scaffold(body: ItemDetailView(reference: reference)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('DetailNavigation', () {
    test('open remembers the way, back walks it in reverse', () {
      var navigation = const DetailNavigation('E-1');
      expect(navigation.canGoBack, isFalse);
      navigation = navigation.open('S-1').open('T-1');
      expect(navigation.current, 'T-1');
      expect(navigation.history, ['E-1', 'S-1']);
      navigation = navigation.back();
      expect(navigation, const DetailNavigation('S-1', ['E-1']));
      expect(navigation.back().back(), const DetailNavigation('E-1'), reason: 'back at the start stays');
    });

    test('going to the item just left is going back, the same item is no move', () {
      final navigation = const DetailNavigation('S-1').open('T-1');
      expect(navigation.open('S-1'), const DetailNavigation('S-1'));
      expect(navigation.open('T-1'), same(navigation));
    });

    test('replace swaps the item without a history entry', () {
      final navigation = const DetailNavigation('E-1').open('S-1').replace('S-2');
      expect(navigation, const DetailNavigation('S-2', ['E-1']));
    });
  });

  group('SiblingPosition', () {
    test('knows its neighbours and prints as "2 / 3"', () {
      final middle = SiblingPosition.of(['A', 'B', 'C'], 'B')!;
      expect('$middle', '2 / 3');
      expect((middle.previous, middle.next), ('A', 'C'));
      final first = SiblingPosition.of(['A', 'B', 'C'], 'A')!;
      expect((first.previous, first.next), (null, 'B'));
      expect(SiblingPosition.of(['A', 'B', 'C'], 'C')!.next, isNull);
      expect(SiblingPosition.of(['A'], 'X'), isNull);
    });
  });

  group('item body', () {
    const body =
        '## Plan\n- [x] pick a tool\n  - [ ] nested step\n```\n- [ ] not an item\n```\n1. [ ] numbered\r\nend\n';

    test('toggleChecklistItem flips one box and keeps everything else', () {
      expect(toggleChecklistItem(body, 0), body.replaceFirst('- [x] pick', '- [ ] pick'));
      expect(toggleChecklistItem(body, 1), body.replaceFirst('- [ ] nested', '- [x] nested'));
      expect(toggleChecklistItem(body, 2), body.replaceFirst('1. [ ]', '1. [x]'), reason: 'code fences are skipped');
      expect(toggleChecklistItem(body, 3), body);
      expect(toggleChecklistItem('- [X] upper', 0), '- [ ] upper');
    });

    test('splitChecklist cuts the body into Markdown and numbered checklist items', () {
      final segments = splitChecklist(body);
      expect(segments.map((s) => s.runtimeType), [
        MarkdownSegment,
        ChecklistSegment,
        ChecklistSegment,
        MarkdownSegment,
        ChecklistSegment,
        MarkdownSegment,
      ]);
      final items = segments.whereType<ChecklistSegment>().toList();
      expect(items.map((i) => (i.index, i.checked, i.text, i.depth)), [
        (0, true, 'pick a tool', 0),
        (1, false, 'nested step', 1),
        (2, false, 'numbered', 0),
      ]);
      expect((segments[3] as MarkdownSegment).markdown, contains('not an item'));
    });

    test('excerpt is the first lines of prose as plain text', () {
      expect(
        excerpt('## Context\nRun a **full** restore.\n\n- time it\n```\ncode\n```\n> quoted\nmore'),
        'Run a full restore. time it quoted',
      );
      expect(excerpt('# Only a heading'), '');
    });
  });

  group('ItemDetailView', () {
    testWidgets('the breadcrumb leads to the parent and back returns', (tester) async {
      await _pumpDetail(tester, 'T-1');
      expect(find.text('Item E-1'), findsOneWidget);
      expect(find.text('T-1 Item T-1'), findsOneWidget);
      expect(_key('detail-back'), findsNothing);

      await _tap(tester, _key('ancestor-S-2'));
      expect(find.text('S-2 Item S-2'), findsOneWidget);
      expect(find.text('Story 2 of 3'), findsOneWidget);
      await _tap(tester, _key('detail-back'));
      expect(find.text('T-1 Item T-1'), findsOneWidget);
      expect(_key('detail-back'), findsNothing);
    });

    testWidgets("the sibling arrows walk the parent's children", (tester) async {
      await _pumpDetail(tester, 'S-1');
      expect(find.text('1 / 3'), findsOneWidget);
      final previous = find.descendant(of: _key('sibling-previous'), matching: find.byType(IconButton));
      expect(tester.widget<IconButton>(previous).onPressed, isNull);
      await _tap(tester, _key('sibling-next'));
      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('S-2 Item S-2'), findsOneWidget);
      await _tap(tester, _key('sibling-next'));
      expect(find.text('3 / 3'), findsOneWidget);
      expect(_key('detail-back'), findsNothing, reason: 'siblings are no history');
    });

    testWidgets('an item without a parent has no sibling arrows', (tester) async {
      await _pumpDetail(tester, 'E-1');
      expect(find.text('Epic · E-1'), findsOneWidget);
      expect(_key('sibling-position'), findsNothing);
    });

    testWidgets('a child expands in place and opens from there', (tester) async {
      await _pumpDetail(tester, 'S-2');
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('1 of 2 done'), findsOneWidget);
      expect(find.text('Record restore time into the runbook.'), findsNothing);

      await _tap(tester, _key('expand-T-1'));
      expect(find.text('Record restore time into the runbook.'), findsOneWidget);
      expect(find.text('Subtasks 0 of 1 done'), findsOneWidget);
      await _tap(tester, _key('open-T-1'));
      expect(find.text('T-1 Item T-1'), findsOneWidget);
      await _tap(tester, _key('detail-back'));
      expect(find.text('S-2 Item S-2'), findsOneWidget);
    });

    testWidgets('relations fold, open linked items and hide when empty', (tester) async {
      await _pumpDetail(tester, 'S-2');
      expect(_key('relation-related'), findsNothing);
      expect(_key('relation-dependents'), findsNothing);
      expect(_key('link-S-1'), findsNothing, reason: 'relations start folded');
      await _tap(tester, _key('relation-dependencies'));
      await _tap(tester, _key('link-S-1'));
      expect(find.text('S-1 Item S-1'), findsOneWidget);
      expect(_key('relation-dependents'), findsOneWidget, reason: 'S-1 blocks S-2');
    });
  });

  group('ItemDetailView fields', () {
    testWidgets('status and priority pills set the field', (tester) async {
      final api = await _pumpDetail(tester, 'T-2');
      final selected = tester.widget<Semantics>(
        find.ancestor(of: _key('status-todo'), matching: find.byType(Semantics)).first,
      );
      expect(selected.properties.checked, isTrue);
      await _tap(tester, _key('status-in-progress'));
      await _tap(tester, _key('priority-p0'));
      expect(api.updates.map((u) => u.$2.changes), [
        ['status=in-progress'],
        ['priority=p0'],
      ]);
    });

    testWidgets('the title is saved on Enter', (tester) async {
      final api = await _pumpDetail(tester, 'T-2');
      await tester.enterText(_key('title-field'), 'Renamed');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(api.updates.single.$2.changes, ['title=Renamed']);
    });
  });

  testWidgets('a checklist checkbox rewrites its line and saves the body', (tester) async {
    final api = await _pumpDetail(tester, 'S-2');
    expect(tester.widget<Checkbox>(_key('checklist-0')).value, isFalse);
    await _tap(tester, _key('checklist-0'));
    expect(api.updates.single.$2.body, '## Plan\nTime the restore.\n- [x] script\n');
    expect(tester.widget<Checkbox>(_key('checklist-0')).value, isTrue);
  });
}
