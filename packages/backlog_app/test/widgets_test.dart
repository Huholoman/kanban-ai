import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/board/presentation/view_layouts.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:flutter/gestures.dart';
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
    expect(find.text('ui'), findsOneWidget);
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

  testWidgets('on a phone New item is a full page', (tester) async {
    final api = await pumpApp(tester, width: 400);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-item-page')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('new-item-page'))).width, 400);
    await tester.enterText(find.byKey(const ValueKey('new-title')), 'From the phone');
    await tester.enterText(find.byKey(const ValueKey('new-body')), 'Some words');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(api.createdItems.single.title, 'From the phone');
    expect(api.createdItems.single.body, 'Some words');
    expect(find.byKey(const ValueKey('new-item-page')), findsNothing);
  });

  testWidgets('the parent of a new item is searched by id or title', (tester) async {
    final api = await pumpApp(
      tester,
      items: [
        item('E', type: 'epic'),
        item('T-1'),
        item('D', status: 'done'),
      ],
    );
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('new-title')), 'Under the epic');
    await tester.enterText(find.byKey(const ValueKey('new-parent-field')), 'item');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parent-option-E')), findsOneWidget);
    expect(find.byKey(const ValueKey('parent-option-D')), findsNothing, reason: 'done items are not offered');
    await tester.tap(find.byKey(const ValueKey('parent-option-E')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('new-parent')), matching: find.text('E Item E')),
      findsOneWidget,
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(api.createdItems.single.parent, 'E');
    expect(api.createdItems.single.type, 'story', reason: 'the child type of an epic');
  });

  testWidgets('Add child in the detail opens the dialog under the item', (tester) async {
    final api = await pumpApp(
      tester,
      items: [
        item('S', type: 'story'),
        item('T-1'),
      ],
    );
    await tester.tap(find.text('Item S'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-child')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('new-parent')), matching: find.text('S Item S')),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('new-title')), 'A step');
    await tester.tap(find.byKey(const ValueKey('new-parent-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-parent-field')), findsOneWidget, reason: 'the parent can be cleared');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.createdItems, isEmpty);

    await tester.tap(find.byKey(const ValueKey('add-child')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('new-title')), 'A step');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(api.createdItems.single.parent, 'S');
    expect(api.createdItems.single.type, 'task');
    expect(find.text('A step'), findsOneWidget, reason: 'the new item opens');
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
    await pumpApp(tester, width: 500);
    expect(find.byKey(const ValueKey('view-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('page-in-progress'))); // one column at a time
    await tester.pumpAndSettle();
    await tester.tap(find.text('Item T-2'));
    await tester.pumpAndSettle();
    expect(find.text('Item T-1'), findsNothing);
    expect(find.byTooltip('Close'), findsOneWidget);
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

  testWidgets('an epic header shows its status and moves by drag or its Move to menu', (tester) async {
    final api = await pumpApp(
      tester,
      items: [
        item('E', type: 'epic', status: 'in-progress'),
        item('S1', parent: 'E'),
      ],
    );
    expect(find.byKey(const ValueKey('parent-status-E')), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('parent-E'))));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(find.text('done')) + const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(api.updates.single.$1, 'E');
    expect(api.updates.single.$2.changes, ['status=done']);

    api.updates.clear();
    await tester.tap(find.byKey(const ValueKey('move-menu-E')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-E-to-todo')));
    await tester.pumpAndSettle();
    expect(api.updates.single.$2.changes, ['status=todo']);
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
    await tester.tap(find.byKey(const ValueKey('filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-label-ui')).first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1300, 800)); // close the popover
    await tester.pumpAndSettle();

    expect(find.text('Item T-1'), findsOneWidget);
    expect(find.text('Item T-3'), findsOneWidget);
    expect(find.text('Item T-2'), findsNothing);
    expect(find.text('label: ui'), findsOneWidget);
    expect(find.text('2 of 3 shown ·'), findsOneWidget);

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

  testWidgets('every column is as tall as the longest, so a card from the bottom drops next to it', (tester) async {
    final api = await pumpApp(tester, items: [for (var i = 1; i <= 30; i++) item('T-$i')]);
    final columns = find.descendant(of: find.byType(KanbanBoard), matching: find.byType(DragTarget<ItemDto>));
    final heights = {for (final column in columns.evaluate()) tester.getSize(find.byWidget(column.widget)).height};
    expect(heights, hasLength(1));
    expect(heights.single, greaterThan(900));

    final card = find.byKey(const ValueKey('card-T-30'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final start = tester.getCenter(card);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(tester.getCenter(find.text('done')).dx, start.dy));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(api.updates.single.$2.changes, ['status=done']);
  });

  testWidgets('Page Down, End and Home scroll the board, but not while typing', (tester) async {
    await pumpApp(tester, items: [for (var i = 1; i <= 30; i++) item('T-$i')]);
    final scrollable = find.descendant(of: find.byType(KanbanBoard), matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);

    await tester.tap(find.byKey(const ValueKey('filter-search')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('the board scrollbar can be dragged with the mouse', (tester) async {
    await pumpApp(tester, items: [for (var i = 1; i <= 30; i++) item('T-$i')]);
    final scrollable = find.descendant(of: find.byType(KanbanBoard), matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThan(0));

    final board = tester.getRect(find.byType(KanbanBoard));
    final gesture = await tester.startGesture(Offset(board.right - 3, board.top + 20), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('children open inside the panel next to the board, Esc closes it', (tester) async {
    await pumpApp(
      tester,
      width: 1900,
      items: [
        item('E-1', type: 'epic'),
        item('S-1', type: 'story', parent: 'E-1'),
        item('T-1', parent: 'S-1'),
      ],
    );
    await tester.tap(find.text('Item E-1'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailView), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('link-S-1')).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open-S-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-S-1')));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailView), findsOneWidget);
    expect(find.byKey(const ValueKey('ancestor-E-1')), findsOneWidget);
    expect(find.byType(KanbanBoard), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailView), findsNothing);
  });

  testWidgets('relations fold, show counts and hide when empty', (tester) async {
    await pumpApp(
      tester,
      items: [
        item('S-1', type: 'story'),
        item('T-1', parent: 'S-1'),
        item('T-2', parent: 'S-1', status: 'done'),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('card-S-1')));
    await tester.pumpAndSettle();
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('1 of 2 done'), findsOneWidget);
    expect(find.text('Parent (0)'), findsNothing);
    expect(find.byKey(const ValueKey('relation-dependencies')), findsNothing);
    expect(find.byKey(const ValueKey('add-dependencies')), findsOneWidget);

    expect(find.byKey(const ValueKey('link-T-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relation-children')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('link-T-1')), findsNothing);
    expect(find.text('Tasks'), findsOneWidget);
  });

  testWidgets('colours from backlog.yaml reach cards and the theme switch works', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeBacklogApi([
      item('T-1', labels: ['ui']),
    ])..appearance = const AppearanceDto(labels: {'ui': '#d81b60'}, priorities: {'p2': '#00ff00'});
    await tester.pumpWidget(BacklogApp(api: api));
    await tester.pumpAndSettle();

    final label = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey('card-T-1')), matching: find.text('ui')),
    );
    expect(label.style?.color, const Color(0xFFD81B60));
    final priority = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey('card-T-1')), matching: find.text('p2')),
    );
    expect(priority.style?.color, const Color(0xFF00FF00));

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);
    await tester.tap(find.byKey(const ValueKey('theme-mode')));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.light);
  });

  testWidgets('columns of a view are picked in a dialog', (tester) async {
    final api = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('edit-columns')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('column-backlog')), findsOneWidget, reason: 'workflow statuses not shown yet');

    await tester.tap(find.byKey(const ValueKey('column-done')));
    await tester.tap(find.byKey(const ValueKey('column-backlog')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.viewColumns['board'], ['todo', 'in-progress', 'backlog']);
    expect(find.text('done'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('edit-columns')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(api.viewColumns, isEmpty);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('a filter is saved as a view and the board switches to it', (tester) async {
    final api = await pumpApp(tester);
    expect(find.byKey(const ValueKey('filter-save')), findsNothing, reason: 'nothing to save without a filter');
    await tester.tap(find.byKey(const ValueKey('filter-flag-ready')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filter-save')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('save-view-name')), 'Ready now');
    await tester.enterText(find.byKey(const ValueKey('save-view-section')), 'Mine');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final request = api.createdViews.single;
    expect(request.name, 'Ready now');
    expect(request.section, 'Mine');
    expect(request.base, 'board');
    expect(request.conditions, [
      {'ready': true},
    ]);
    expect(find.byKey(const ValueKey('section-Mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-clear')), findsNothing, reason: 'the view filters now');
  });
}
