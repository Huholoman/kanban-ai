import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/board/presentation/item_card.dart';
import 'package:backlog_app/features/board/presentation/view_layouts.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _now = DateTime.utc(2026, 1, 1, 12);

ClaimDto claim({Duration left = const Duration(hours: 1), bool expired = false}) => ClaimDto(
  item: 'T-1',
  agent: 'agent-7',
  claimedAt: _now.subtract(const Duration(hours: 1)),
  heartbeatAt: _now,
  expiresAt: _now.add(left),
  expired: expired,
);

Future<void> pumpCard(WidgetTester tester, ItemDto dto, {bool selected = false}) => tester.pumpWidget(
  MaterialApp(
    theme: BoardTokens.light.toTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(
        width: 240,
        child: ItemCard(item: dto, selected: selected, now: _now),
      ),
    ),
  ),
);

CardBorderPainter borderOf(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(find.byKey(const ValueKey('card-T-1')));
  return paint.foregroundPainter! as CardBorderPainter;
}

ItemDto base({
  bool ready = false,
  bool blocked = false,
  List<String> blockedBy = const [],
  ClaimDto? claim,
  String status = 'todo',
  List<String> labels = const [],
}) {
  final i = item('T-1', status: status, labels: labels);
  return ItemDto(
    id: i.id,
    title: i.title,
    type: i.type,
    status: i.status,
    category: i.category,
    priority: i.priority,
    labels: i.labels,
    ready: ready,
    blocked: blocked,
    blockedBy: blockedBy,
    claim: claim,
  );
}

void main() {
  testWidgets('a ready item says so', (tester) async {
    await pumpCard(tester, base(ready: true, labels: ['ui']));
    expect(find.text('● Ready'), findsOneWidget);
    expect(find.text('ui'), findsNothing, reason: 'one meta line only');
  });

  testWidgets('a blocked item names its blockers', (tester) async {
    await pumpCard(tester, base(blocked: true, blockedBy: ['T-9']));
    expect(find.text('Blocked by T-9'), findsOneWidget);
  });

  testWidgets('a claim shows the agent and the time left', (tester) async {
    await pumpCard(tester, base(claim: claim()));
    expect(find.text('◉ agent-7 · 1h left'), findsOneWidget);
    expect(borderOf(tester).dashed, isFalse);
    expect(ItemCard.timeLeft(_now.add(const Duration(minutes: 25)), _now), '25 min left');
  });

  testWidgets('an expired claim is faint and the border dashed', (tester) async {
    await pumpCard(tester, base(claim: claim(left: const Duration(minutes: -5), expired: true)));
    expect(find.text('Claim expired · agent-7'), findsOneWidget);
    expect(borderOf(tester).dashed, isTrue);
  });

  testWidgets('plain items list their labels', (tester) async {
    await pumpCard(tester, base(labels: ['security', 'launch']));
    expect(find.text('security'), findsOneWidget);
    expect(find.text('launch'), findsOneWidget);
  });

  testWidgets('done cards are dimmed', (tester) async {
    await pumpCard(tester, base(status: 'done'));
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, 0.7);
  });

  testWidgets('the selected card has a 2 px accent border', (tester) async {
    await pumpCard(tester, base(), selected: true);
    final border = borderOf(tester);
    expect(border.width, 2);
    expect(border.color, BoardTokens.light.accent);
  });

  group('kanban board', () {
    ViewResultDto board() => ViewResultDto(
      id: 'board',
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      groups: [
        ViewGroupDto('todo', [item('A'), item('B')]),
        const ViewGroupDto('in-progress', []),
        ViewGroupDto('done', [item('C', status: 'done')]),
      ],
    );

    Future<void> pumpBoard(WidgetTester tester, double width, {bool stacked = false}) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: BoardTokens.light.toTheme(Brightness.light),
          home: Scaffold(
            body: KanbanBoard(result: board(), onOpen: (_) {}, stacked: stacked),
          ),
        ),
      );
    }

    testWidgets('columns share a wide window up to the maximum width', (tester) async {
      await pumpBoard(tester, 1900);
      expect(tester.getSize(find.byKey(const ValueKey('card-A'))).width, KanbanBoard.maxColumnWidth - 16);
    });

    testWidgets('columns shrink to the minimum width on narrow windows', (tester) async {
      await pumpBoard(tester, 600);
      expect(tester.getSize(find.byKey(const ValueKey('card-A'))).width, KanbanBoard.minColumnWidth - 16);
      expect(KanbanBoard.columnWidthFor(1000, 3), inInclusiveRange(196, 280));
    });

    testWidgets('stacked mode shows sections one under another and hides empty ones', (tester) async {
      await pumpBoard(tester, 400, stacked: true);
      expect(find.text('todo'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
      expect(find.text('in-progress'), findsNothing);
      final a = tester.getRect(find.byKey(const ValueKey('card-A')));
      final c = tester.getRect(find.byKey(const ValueKey('card-C')));
      expect(c.top, greaterThan(a.bottom));
      expect(a.width, greaterThan(300), reason: 'cards use the full width');
    });
  });
}
