import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/board/presentation/view_layouts.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  Future<FakeBacklogApi> pumpApp(WidgetTester tester, {double width = 1400, double height = 900}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeBacklogApi([item('T-1'), item('T-2', status: 'in-progress', body: '## Plan')]);
    await tester.pumpWidget(BacklogApp(api: api));
    await tester.pumpAndSettle();
    return api;
  }

  group('navigation', () {
    testWidgets('shows view counts and the lint summary at the bottom', (tester) async {
      await pumpApp(tester);
      expect(find.descendant(of: find.byKey(const ValueKey('view-board')), matching: find.text('2')), findsOneWidget);
      expect(find.text('KANBAN-AI'), findsNothing);
      expect(find.text('kanban-ai'), findsOneWidget);
      expect(find.text('Lint: all good'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Lint: all good')).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('view-board'))).dy),
      );
    });

    testWidgets('a view is pinned to the bottom bar and unpinned again from its menu', (tester) async {
      final api = await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('view-menu-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to bottom bar'));
      await tester.pumpAndSettle();
      expect(api.pinnedViews, {'list'});

      await tester.tap(find.byKey(const ValueKey('view-menu-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin from bottom bar'));
      await tester.pumpAndSettle();
      expect(api.pinnedViews, isEmpty);
    });

    testWidgets('a tablet has view tabs and a drawer with the full navigation', (tester) async {
      await pumpApp(tester, width: 1000);
      expect(find.byKey(const ValueKey('tab-board')), findsOneWidget);
      expect(find.byKey(const ValueKey('view-board')), findsNothing, reason: 'no side navigation');
      await tester.tap(find.byKey(const ValueKey('tab-list')));
      await tester.pumpAndSettle();
      expect(find.byType(GroupedItemList), findsOneWidget);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('view-board')), findsOneWidget);
      expect(find.text('Lint: all good'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('view-board')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('view-board')), findsNothing, reason: 'the drawer closed');
      expect(find.byType(KanbanBoard), findsOneWidget);
    });

    testWidgets('a phone has a bottom bar with the first two views when nothing is pinned', (tester) async {
      await pumpApp(tester, width: 400);
      expect(find.byKey(const ValueKey('bottom-view-saved-1')), findsNothing);
      expect(find.byKey(const ValueKey('bottom-view-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('bottom-view-board')), findsOneWidget);
      expect(find.byKey(const ValueKey('bottom-more')), findsOneWidget);
    });

    testWidgets('pinned views are in the phone bottom bar', (tester) async {
      final api = await pumpApp(tester, width: 400);
      api.pinnedViews.add('list');
      await tester.tap(find.byKey(const ValueKey('bottom-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('view-menu-board')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to bottom bar'));
      await tester.pumpAndSettle();
      expect(api.pinnedViews, {'list', 'board'});
      await tester.tap(find.byKey(const ValueKey('view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bottom-view-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('bottom-view-board')), findsOneWidget);
    });
  });

  group('detail', () {
    testWidgets('is a panel next to the board on a wide screen, Esc closes it', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Item T-2'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailView), findsOneWidget);
      expect(find.byType(KanbanBoard), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-sheet')), findsNothing);
      expect(tester.getSize(find.byType(ItemDetailView)).width, 480);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ItemDetailView), findsNothing);
    });

    testWidgets('is a bottom sheet over the board on a tablet', (tester) async {
      await pumpApp(tester, width: 1000);
      await tester.tap(find.text('Item T-2'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-sheet')), findsOneWidget);
      expect(find.byType(KanbanBoard), findsOneWidget, reason: 'the board stays visible');

      await tester.tap(find.byKey(const ValueKey('open-full')));
      await tester.pumpAndSettle();
      expect(find.byType(ItemPage), findsOneWidget);
    });

    testWidgets('is a full page on a phone', (tester) async {
      await pumpApp(tester, width: 500);
      await tester.tap(find.text('Item T-2'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemPage), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-sheet')), findsNothing);
    });
  });

  testWidgets('the / key focuses the search field', (tester) async {
    await pumpApp(tester);
    final search = find.descendant(
      of: find.byKey(const ValueKey('filter-search')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(search).focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(tester.widget<EditableText>(search).focusNode.hasFocus, isTrue);
  });

  testWidgets('phones get the board as stacked sections', (tester) async {
    await pumpApp(tester, width: 400);
    expect(tester.widget<KanbanBoard>(find.byType(KanbanBoard)).stacked, isTrue);
  });
}
