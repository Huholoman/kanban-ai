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
}
