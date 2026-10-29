import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/board/presentation/view_layouts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  Future<FakeBacklogApi> pumpApp(WidgetTester tester, {double width = 1400, List<ItemDto>? items}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeBacklogApi(
      items ??
          [
            item('T-1', priority: 'p0', labels: ['ui']),
            item('T-2', status: 'in-progress', body: '## Plan\n- [x] step'),
          ],
    );
    await tester.pumpWidget(BacklogApp(api: api));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('the board shows columns and cards', (tester) async {
    await pumpApp(tester);
    expect(find.text('Board'), findsWidgets); // title and the views panel
    expect(find.text('todo'), findsOneWidget);
    expect(find.text('in-progress'), findsOneWidget);
    expect(find.text('Item T-1'), findsOneWidget);
    expect(find.text('#ui'), findsOneWidget);
  });

  testWidgets('dragging a card to another column changes its status', (tester) async {
    final api = await pumpApp(tester);
    final card = find.byKey(const ValueKey('card-T-1'));
    final target = tester.getCenter(find.text('done')) + const Offset(0, 120);
    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(api.updates.single.$2.changes, ['status=done']);
  });

  testWidgets('tapping a card opens the detail with the rendered body', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Item T-2'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Claim'), findsOneWidget);
  });

  testWidgets('the body can be edited', (tester) async {
    final api = await pumpApp(tester);
    await tester.tap(find.text('Item T-2'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('body-editor')), 'Rewritten');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.updates.single.$2.body, 'Rewritten\n');
    expect(find.text('Rewritten'), findsOneWidget);
  });

  testWidgets('new items are created from the dialog', (tester) async {
    final api = await pumpApp(tester);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('new-title')), 'Fresh idea');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(api.items_.values.map((i) => i.title), contains('Fresh idea'));
    expect(find.text('Fresh idea'), findsOneWidget); // detail opened
  });

  testWidgets('on a wide screen the detail opens next to the board', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Item T-2'));
    await tester.pumpAndSettle();
    expect(find.text('Item T-1'), findsOneWidget, reason: 'the board stays visible');
    expect(find.text('Plan'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsNothing);
  });

  testWidgets('on a narrow screen the detail is a page and views are in a dropdown', (tester) async {
    await pumpApp(tester, width: 800);
    expect(find.byKey(const ValueKey('view-picker')), findsOneWidget);
    await tester.tap(find.text('Item T-2'));
    await tester.pumpAndSettle();
    expect(find.text('Item T-1'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('views are switched in the left panel', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('view-list')));
    await tester.pumpAndSettle();
    expect(find.text('All'), findsWidgets);
    expect(find.byType(KanbanBoard), findsNothing);
    expect(find.byType(GroupedItemList), findsOneWidget);
  });

  testWidgets('stories are grouped under their epic, also in other columns', (tester) async {
    await pumpApp(
      tester,
      items: [
        item('E', type: 'epic'),
        item('S1', parent: 'E'),
        item('S2', parent: 'E', status: 'in-progress'),
      ],
    );
    // In todo the epic itself is the head of the group; in in-progress it is a context header.
    expect(find.byKey(const ValueKey('card-E')), findsOneWidget);
    expect(find.byKey(const ValueKey('parent-E')), findsOneWidget);
    final header = tester.getTopLeft(find.byKey(const ValueKey('parent-E')));
    final story = tester.getTopLeft(find.byKey(const ValueKey('card-S2')));
    expect(story.dy, greaterThan(header.dy));
    expect(story.dx, greaterThan(header.dx), reason: 'children are indented');
  });

  testWidgets('the board is filtered by labels from the filter bar', (tester) async {
    await pumpApp(
      tester,
      items: [
        item('T-1', labels: ['ui']),
        item('T-2', labels: ['backend']),
        item('T-3', status: 'in-progress', labels: ['ui', 'web']),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('filter-label')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-label-ui')).first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 800)); // close the menu
    await tester.pumpAndSettle();

    expect(find.text('Item T-1'), findsOneWidget);
    expect(find.text('Item T-3'), findsOneWidget);
    expect(find.text('Item T-2'), findsNothing);
    expect(find.text('Labels: ui'), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Item T-2'), findsOneWidget);
  });

  testWidgets('the search field filters by title', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const ValueKey('filter-search')), 'item t-2');
    await tester.pumpAndSettle();
    expect(find.text('Item T-1'), findsNothing);
    expect(find.text('Item T-2'), findsOneWidget);
  });

  testWidgets('a story folds its tasks away', (tester) async {
    await pumpApp(
      tester,
      items: [
        item('S-1', type: 'story'),
        item('T-1', parent: 'S-1'),
        item('T-2', parent: 'S-1'),
      ],
    );
    expect(find.text('Item T-1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fold-S-1')));
    await tester.pumpAndSettle();
    expect(find.text('Item S-1'), findsOneWidget);
    expect(find.text('Item T-1'), findsNothing);
    expect(find.text('2 hidden'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fold-S-1')));
    await tester.pumpAndSettle();
    expect(find.text('Item T-2'), findsOneWidget);
  });

  testWidgets('a view is moved into a section that folds', (tester) async {
    final api = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('view-menu-board')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-view-board')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('section-name')), 'Planning');
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();

    expect(api.viewSections, {'board': 'Planning'});
    expect(find.byKey(const ValueKey('section-Planning')), findsOneWidget);
    expect(find.byKey(const ValueKey('view-board')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('section-Planning')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('view-board')), findsNothing);
    expect(find.byKey(const ValueKey('view-list')), findsOneWidget);
  });

  testWidgets('clicking an id copies it', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('copy-T-1')));
    await tester.pump();
    expect(copied, 'T-1');
    expect(find.text('Copied T-1'), findsOneWidget);
  });
}
