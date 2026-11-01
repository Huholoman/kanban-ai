import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
import 'package:backlog_app/features/board/presentation/filter_bar.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  Future<FakeBacklogApi> pumpApp(WidgetTester tester, List<ItemDto> items) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeBacklogApi(items);
    await tester.pumpWidget(BacklogApp(api: api));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  final items = [
    item('T-1', labels: ['ui'], priority: 'p0'),
    item('T-2', labels: ['backend'], priority: 'p1'),
    item('T-3', status: 'in-progress', labels: ['ui', 'web'], priority: 'p3'),
  ];

  testWidgets('the age segments keep only recently changed items', (tester) async {
    await pumpApp(tester, [
      ItemDto(
        id: 'T-1',
        title: 'Fresh',
        type: 'task',
        status: 'todo',
        priority: 'p2',
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      ),
      item('T-2', status: 'todo'),
    ]);
    expect(find.text('Item T-2'), findsOneWidget);
    await tapKey(tester, 'filter-age-day');
    expect(find.text('Fresh'), findsOneWidget);
    expect(find.text('Item T-2'), findsNothing);
    await tapKey(tester, 'filter-age-day');
    expect(find.text('Item T-2'), findsOneWidget);
  });

  testWidgets('ticking a label in the popover filters the board and adds a chip', (tester) async {
    await pumpApp(tester, items);
    await tapKey(tester, 'filter-button');
    expect(find.byKey(const ValueKey('filter-label')), findsOneWidget);
    await tapKey(tester, 'filter-label-ui');

    expect(find.text('Item T-2'), findsNothing);
    expect(find.text('Item T-1'), findsOneWidget);
    expect(find.text('label: ui'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-badge')), findsOneWidget);
    expect(find.text('2 items match'), findsOneWidget);

    // A tap outside an open menu only closes it, so close the popover first.
    await tester.tapAt(const Offset(1300, 800));
    await tester.pumpAndSettle();
    await tapKey(tester, 'chip-label-remove');
    expect(find.text('label: ui'), findsNothing);
    expect(find.text('Item T-2'), findsOneWidget);
  });

  testWidgets('the popover shows how many items carry each label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BoardTokens.light.toTheme(Brightness.light),
        home: Scaffold(
          body: FilterBar(
            filter: BoardFilter.none,
            options: BoardFilter.options(items, null),
            counts: BoardFilter.counts(items),
            shown: 3,
            total: 3,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tapKey(tester, 'filter-button');
    Finder count(String value, String text) => find.descendant(
      of: find.ancestor(of: find.byKey(ValueKey('filter-label-$value')), matching: find.byType(InkWell)).first,
      matching: find.text(text),
    );
    expect(count('ui', '2'), findsOneWidget);
    expect(count('backend', '1'), findsOneWidget);
  });

  testWidgets('many labels get a search box that narrows the list', (tester) async {
    final many = [
      for (var i = 0; i < 10; i++) item('T-$i', labels: ['label$i', if (i == 3 || i == 8) 'infra']),
    ];
    await pumpApp(tester, many);
    await tapKey(tester, 'filter-button');
    // A short list first: the most frequent labels (infra has two items).
    expect(find.byKey(const ValueKey('filter-label-infra')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-label-label9')), findsNothing);
    expect(find.text('Show all (11)'), findsOneWidget);
    await tapKey(tester, 'filter-label-more');
    expect(find.byKey(const ValueKey('filter-label-label9')), findsOneWidget);
    await tapKey(tester, 'filter-label-more');
    expect(find.byKey(const ValueKey('filter-label-label9')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('filter-label-search')), 'inf');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-label-infra')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-label-label7')), findsNothing);
  });

  testWidgets('priorities in a run are shown as a range', (tester) async {
    await pumpApp(tester, [...items, item('T-4', priority: 'p2')]);
    await tapKey(tester, 'filter-button');
    await tapKey(tester, 'filter-priority-p0');
    await tapKey(tester, 'filter-priority-p1');
    expect(find.text('priority: p0–p1'), findsOneWidget);
    await tapKey(tester, 'filter-priority-p3');
    expect(find.text('priority: p0, p1, p3'), findsOneWidget);
  });

  testWidgets('readiness segments toggle flags', (tester) async {
    await pumpApp(tester, items);
    await tapKey(tester, 'filter-flag-ready');
    expect(find.text('Item T-3'), findsNothing, reason: 'the fake items are not ready');
    expect(find.text('Item T-1'), findsNothing);
    expect(find.text('0 of 3 shown ·'), findsOneWidget);
    await tapKey(tester, 'filter-clear');
    expect(find.text('Item T-3'), findsOneWidget);
  });

  testWidgets('a filter is saved as a pinned view in a new section', (tester) async {
    final api = await pumpApp(tester, items);
    await tapKey(tester, 'filter-button');
    await tapKey(tester, 'filter-label-ui');
    await tapKey(tester, 'filter-save');

    await tester.enterText(find.byKey(const ValueKey('save-view-name')), 'UI work');
    await tester.pumpAndSettle();
    expect(find.text('Saved as views/ui-work.yaml (filter + columns + sorting)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('save-view-section')), 'Mine');
    await tapKey(tester, 'save-view-pin');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final request = api.createdViews.single;
    expect(request.name, 'UI work');
    expect(request.section, 'Mine');
    expect(request.pinned, isTrue);
    expect(request.conditions, [
      {
        'labels': ['ui'],
      },
    ]);
  });
}
