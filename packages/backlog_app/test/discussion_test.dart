import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
import 'package:backlog_app/features/board/presentation/item_card.dart';
import 'package:backlog_app/features/dispatch/application/dispatch_controller.dart';
import 'package:backlog_app/features/dispatch/presentation/dispatch_scope.dart';
import 'package:backlog_app/features/item/application/item_body.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

const _body =
    '## Context\n\nExport the report.\n\n- [ ] CSV\n\n'
    '## Discussion\n\n### w1 · 2026-10-31 10:00:00 UTC · question\n\nCSV or JSON?\n';

final _question = CommentDto(author: 'w1', at: DateTime.utc(2026, 10, 31, 10), text: 'CSV or JSON?', question: true);

DispatchDto _plan({required String mode, bool session = true}) => DispatchDto(
  configured: true,
  mode: mode,
  agent: 'claude',
  maxAgents: 1,
  capacity: 1,
  worktrees: const [DispatchWorktreeDto(name: 'w1', path: '/w/w1', busy: false)],
  sessions: [if (session) const AgentSessionDto(item: 'Q-1', session: 'sess-q', worktree: 'w1')],
);

Future<FakeBacklogApi> _pump(WidgetTester tester, {DispatchDto? plan}) async {
  tester.view.physicalSize = const Size(700, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = FakeBacklogApi([item('Q-1', needsHuman: true, body: _body), item('R-1', ready: true)])
    ..discussions['Q-1'] = [_question]
    ..plan = plan ?? DispatchDto.off;
  final dispatch = DispatchController(api, refreshDelay: Duration.zero);
  addTearDown(dispatch.dispose);
  await dispatch.start();
  await tester.pumpWidget(
    AppScope(
      api: api,
      child: MaterialApp(
        theme: BoardTokens.light.toTheme(Brightness.light),
        home: Scaffold(
          body: DispatchScope(
            controller: dispatch,
            child: const ItemDetailView(reference: 'Q-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _reply(WidgetTester tester, String text, String button) async {
  await tester.enterText(_key('reply-field'), text);
  await tester.pump();
  await tester.ensureVisible(_key(button));
  await tester.tap(_key(button));
  await tester.pumpAndSettle();
}

void main() {
  test('splitDiscussion separates the description from the discussion and puts it back', () {
    final parts = splitDiscussion(_body);
    expect(parts.description, '## Context\n\nExport the report.\n\n- [ ] CSV');
    expect(parts.discussion, startsWith('## Discussion\n\n### w1'));
    expect(withDescription('New text.\n', parts.discussion), 'New text.\n\n${parts.discussion}\n');
    expect(splitDiscussion('Plain.\n'), (description: 'Plain.\n', discussion: ''));
    expect(withDescription('Plain.\n', ''), 'Plain.\n');
    final later = splitDiscussion('A\n\n## Discussion\n\n### x · 2026-10-31 10:00\n\nHi\n\n## Notes\n\nB\n');
    expect(later.description, 'A\n\n## Notes\n\nB');
    expect(later.discussion, '## Discussion\n\n### x · 2026-10-31 10:00\n\nHi');
    expect(splitDiscussion('```\n## Discussion\n```\n').discussion, isEmpty);
  });

  test('the Needs you flag filters and becomes a needs_human condition', () {
    final filter = BoardFilter.none.toggleFlag(ItemFlag.needsHuman);
    expect(filter.matches(item('Q-1', needsHuman: true)), isTrue);
    expect(filter.matches(item('R-1')), isFalse);
    expect(filter.toConditions(), [
      {'needs_human': true},
    ]);
  });

  testWidgets('a card that waits for a person says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BoardTokens.light.toTheme(Brightness.light),
        home: Scaffold(body: ItemCard(item: item('Q-1', needsHuman: true))),
      ),
    );
    expect(find.text('? Waits for you'), findsOneWidget);
  });

  testWidgets('the detail shows the question, the description without the discussion and takes an answer', (
    tester,
  ) async {
    final api = await _pump(tester);
    expect(_key('waits-for-you'), findsOneWidget);
    expect(find.text('question · waits for you'), findsOneWidget);
    expect(find.text('CSV or JSON?'), findsOneWidget);
    expect(find.text('Discussion · 1'), findsOneWidget);
    expect(_key('send-and-continue'), findsNothing, reason: 'no dispatcher');

    await _reply(tester, 'CSV, with a header.', 'send-comment');
    expect(api.discussions['Q-1']!.last.text, 'CSV, with a header.');
    expect(find.text('CSV, with a header.'), findsOneWidget);
    expect(_key('waits-for-you'), findsNothing);

    // Editing the description keeps the discussion where it is.
    await tester.ensureVisible(find.text('Edit'));
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final editor = tester.widget<TextField>(_key('body-editor'));
    expect(editor.controller!.text, isNot(contains('Discussion')));
    await tester.enterText(_key('body-editor'), 'Export as CSV.');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.updates.last.$2.body, startsWith('Export as CSV.\n\n## Discussion\n\n### w1 ·'));
  });

  for (final mode in ['manual', 'auto']) {
    testWidgets('in $mode mode Send wakes the agent through the dispatcher, without a start', (tester) async {
      final api = await _pump(tester, plan: _plan(mode: mode));
      expect(_key('send-and-continue'), findsNothing);
      expect(find.text('Send: the agent continues in w1 by itself. Note only: it is not woken.'), findsOneWidget);
      await _reply(tester, 'CSV.', 'send-comment');
      expect(api.started, isEmpty, reason: 'the dispatcher resumes it by itself');
      expect(api.discussions['Q-1']!.last.note, isFalse);
    });
  }

  testWidgets('Note only saves a note that wakes nobody and answers nothing', (tester) async {
    final api = await _pump(tester, plan: _plan(mode: 'auto'));
    await _reply(tester, 'Still deciding.', 'note-only');
    final last = api.discussions['Q-1']!.last;
    expect((last.text, last.note), ('Still deciding.', true));
    expect(api.started, isEmpty);
    expect(find.text('note'), findsOneWidget);
    expect(find.text('question · waits for you'), findsOneWidget, reason: 'the question stays open');
  });

  testWidgets('without a session Note only is offered while a question is open', (tester) async {
    await _pump(tester, plan: _plan(mode: 'auto', session: false));
    expect(_key('note-only'), findsOneWidget);
    await _reply(tester, 'CSV.', 'send-comment');
    expect(_key('note-only'), findsNothing, reason: 'nothing left that a note would keep quiet');
  });
}
