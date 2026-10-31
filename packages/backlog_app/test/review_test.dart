import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
import 'package:backlog_app/features/board/presentation/item_card.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<void> _card(WidgetTester tester, ItemDto item) => tester.pumpWidget(
  MaterialApp(
    theme: BoardTokens.light.toTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(width: 320, child: ItemCard(item: item)),
    ),
  ),
);

void main() {
  testWidgets('a card shows where the AI review stands', (tester) async {
    for (final (review, findings, text) in [
      ('running', 0, 'AI review…'),
      ('ok', 0, 'AI review ✓'),
      ('changes', 3, 'AI review: 3 findings'),
      ('changes', 1, 'AI review: 1 finding'),
      ('changes', 0, 'AI review: changes'),
      ('stale', 2, 'AI review outdated'),
    ]) {
      await _card(tester, item('T-1', status: 'in-progress', review: review, reviewFindings: findings));
      expect(find.text(text), findsOneWidget, reason: '$review $findings');
      expect(find.byKey(const ValueKey('review-T-1')), findsOneWidget);
    }
    await _card(tester, item('T-1', status: 'in-progress', labels: ['ui']));
    expect(find.byKey(const ValueKey('review-T-1')), findsNothing);
    expect(find.text('ui'), findsOneWidget);
    await _card(tester, item('T-1', status: 'done', review: 'ok'));
    expect(find.byKey(const ValueKey('review-T-1')), findsNothing, reason: 'done items keep it quiet');
  });

  test('the AI review facet filters by state and becomes a review condition', () {
    final items = [
      item('A', review: 'changes', reviewFindings: 2),
      item('B', review: 'ok'),
      item('C'),
      item('D', review: 'running'),
    ];
    final filter = BoardFilter.none.toggle(FilterFacet.review, 'changes').toggle(FilterFacet.review, 'running');
    expect(items.where(filter.matches).map((i) => i.id), ['A', 'D']);
    expect(filter.toConditions(), [
      {
        'review': ['changes', 'running'],
      },
    ]);
    expect(BoardFilter.options(items, null)[FilterFacet.review], ['running', 'changes', 'ok']);
    expect(FilterFacet.review.describe('stale', const {}), 'Outdated');
  });

  testWidgets('the detail tags the review state and review comments', (tester) async {
    tester.view.physicalSize = const Size(700, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api =
        FakeBacklogApi([item('Q-1', status: 'in-progress', review: 'changes', reviewFindings: 2, body: 'Export.\n')])
          ..discussions['Q-1'] = [
            CommentDto(
              author: 'w2',
              at: DateTime.utc(2026, 10, 31, 10),
              text: 'Two things.\n\n1. a\n2. b',
              review: 'changes',
              commit: '1a2b3c4d5e6f',
            ),
            CommentDto(author: 'w3', at: DateTime.utc(2026, 10, 31, 11), text: 'Fine now.', review: 'ok'),
          ];
    await tester.pumpWidget(
      AppScope(
        api: api,
        child: MaterialApp(
          theme: BoardTokens.light.toTheme(Brightness.light),
          home: const Scaffold(body: ItemDetailView(reference: 'Q-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI review: 2 findings'), findsOneWidget);
    expect(find.text('review: 2 findings'), findsOneWidget);
    expect(find.text('1a2b3c4'), findsOneWidget);
    expect(find.text('review ✓'), findsOneWidget);
  });
}
