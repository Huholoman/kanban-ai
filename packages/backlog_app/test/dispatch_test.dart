import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
import 'package:backlog_app/features/dispatch/application/agent_log_controller.dart';
import 'package:backlog_app/features/dispatch/application/dispatch_controller.dart';
import 'package:backlog_app/features/dispatch/presentation/dispatch_overview.dart';
import 'package:backlog_app/features/dispatch/presentation/dispatch_scope.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _started = DateTime.utc(2026, 10, 31, 12);

DispatchDto _plan({bool running = false, bool free = true, List<HeldItemDto> held = const []}) => DispatchDto(
  configured: true,
  mode: 'manual',
  agent: 'claude',
  maxAgents: 2,
  running: running ? 1 : 0,
  capacity: free ? (running ? 1 : 2) : 0,
  worktrees: [
    DispatchWorktreeDto(
      name: 'w1',
      path: '/w/w1',
      busy: running,
      claims: running ? const ['R-1'] : const [],
      run: running
          ? AgentRunDto(
              item: 'R-1',
              worktree: 'w1',
              pid: 7,
              startedAt: _started,
              log: '/state/logs/R-1.log',
              agent: 'claude',
              branch: 'agent/R-1',
            )
          : null,
    ),
    DispatchWorktreeDto(name: 'w2', path: '/w/w2', busy: false, unavailable: free ? null : 'uncommitted changes'),
  ],
  assignments: free ? const [DispatchAssignmentDto(item: 'R-2', title: 'Item R-2', worktree: 'w2')] : const [],
  held: held,
);

List<ItemDto> _items() => [
  item('R-1', status: 'in-progress'),
  item('R-2', ready: true),
  item('R-3', ready: true),
  item('B-1', status: 'backlog'),
];

Future<(FakeBacklogApi, DispatchController)> _pumpDetail(
  WidgetTester tester,
  String reference,
  DispatchDto plan,
) async {
  tester.view.physicalSize = const Size(700, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = FakeBacklogApi(_items())..plan = plan;
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 220,
                  child: ListView(children: [DispatchOverview(onOpenItem: (_) {})]),
                ),
                Expanded(child: ItemDetailView(reference: reference)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api, dispatch);
}

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  group('DispatchController', () {
    test('loads the plan and tells which items can start', () async {
      final api = FakeBacklogApi(_items())..plan = _plan(running: true);
      final controller = DispatchController(api, refreshDelay: Duration.zero);
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.configured, isTrue);
      expect(controller.runFor('R-1')!.worktree, 'w1');
      expect(controller.canStart(api.items_['R-2']!), isTrue);
      expect(controller.canStart(api.items_['B-1']!), isFalse, reason: 'not ready');

      api.dispatchChange(_plan(running: true, free: false));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.canStart(api.items_['R-2']!), isFalse, reason: 'no free worktree');
    });

    test('start and stop go to the API and report back; failures become notices', () async {
      final api = FakeBacklogApi(_items())
        ..plan = _plan()
        ..afterStart = _plan(running: true);
      final controller = DispatchController(api, refreshDelay: Duration.zero);
      addTearDown(controller.dispose);
      final notices = <String>[];
      controller.notices.listen(notices.add);
      await controller.start();

      await controller.startAgent('R-1');
      expect(api.started, ['R-1']);
      expect(controller.runFor('R-1'), isNotNull);
      api.failStart = const BacklogApiException(409, 'unavailable', 'No free worktree for R-3.');
      await controller.startAgent('R-3');
      await controller.stopAgent('R-1');
      await Future<void>.delayed(Duration.zero);
      expect(api.stopped, ['R-1']);
      expect(notices, ['Started claude for R-1 in w1.', 'No free worktree for R-3.', 'Stopped the agent of R-1.']);
    });

    test('an old server without the dispatcher API means no dispatcher', () async {
      final controller = DispatchController(_NoDispatchApi(FakeBacklogApi(_items())), refreshDelay: Duration.zero);
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.configured, isFalse);
    });
  });

  testWidgets('a ready item has Start agent; the overview proposes and starts', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-2', _plan());
    expect(_key('start-agent'), findsOneWidget);
    expect(find.text('AGENTS · MANUAL · 0/2'), findsOneWidget);
    expect(find.text('w1 · free'), findsOneWidget);
    expect(find.text('R-2 → w2'), findsOneWidget);

    await tester.tap(_key('start-agent'));
    await tester.pumpAndSettle();
    expect(api.started, ['R-2']);
    await tester.tap(_key('start-R-2'));
    await tester.pumpAndSettle();
    expect(api.started, ['R-2', 'R-2']);
  });

  testWidgets('no Start without a free worktree or for items that are not ready', (tester) async {
    await _pumpDetail(tester, 'R-3', _plan(free: false));
    expect(_key('start-agent'), findsNothing);
    expect(find.text('w2 · unavailable'), findsOneWidget);
  });

  testWidgets('a worktree the dispatcher would create shows as new; Start works without a free one', (tester) async {
    const plan = DispatchDto(
      configured: true,
      mode: 'manual',
      agent: 'claude',
      maxAgents: 2,
      capacity: 2,
      maxWorktrees: 2,
      spareWorktrees: 2,
      worktrees: [
        DispatchWorktreeDto(name: 'app-2', path: '/w/app-2', busy: false, unavailable: 'uncommitted changes'),
        DispatchWorktreeDto(name: 'app-3', path: '/w/app-3', busy: false, created: true, isNew: true),
      ],
      assignments: [DispatchAssignmentDto(item: 'R-2', title: 'Item R-2', worktree: 'app-3', newWorktree: true)],
    );
    expect(DispatchDto.fromJson(plan.toJson()).toJson(), plan.toJson());
    await _pumpDetail(tester, 'R-3', plan);
    expect(find.text('AGENTS · MANUAL · 0/2 · 1/2 WORKTREES'), findsOneWidget);
    expect(find.text('app-3 · new'), findsOneWidget);
    expect(find.text('R-2 → app-3 (new)'), findsOneWidget);
    expect(_key('start-agent'), findsOneWidget, reason: 'a worktree can be created');
  });

  testWidgets('a running agent shows where and since when, its log and a Stop button', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-1', _plan(running: true));
    expect(find.text('w1 · R-1'), findsOneWidget);
    expect(find.textContaining('Agent claude in w1 since'), findsOneWidget);
    expect(find.textContaining('agent/R-1'), findsWidgets);

    expect(api.followedLogs, ['R-1']);
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(item: 'R-1', path: '/state/logs/R-1.log', running: true, reset: true, lines: ['hello']),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('hello'), findsOneWidget, reason: 'the live log is open while the agent runs');
    expect(find.text('Live · /state/logs/R-1.log'), findsOneWidget);
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(item: 'R-1', path: '/state/logs/R-1.log', running: true, lines: ['▸ Bash git status']),
    );
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('▸ Bash git status'), findsOneWidget);
    await tester.tap(find.text('Hide log'));
    await tester.pump();
    expect(find.text('hello'), findsNothing);

    api.afterStop = _plan(
      held: const [HeldItemDto(item: 'R-1', title: 'Item R-1', reason: 'stopped by a person')],
    );
    await tester.tap(_key('stop-agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(api.stopped, ['R-1']);
    expect(find.text('Held: stopped by a person'), findsOneWidget);
    expect(find.text('R-1 held'), findsOneWidget);
  });

  testWidgets('after the run the detail keeps the Agent box with the last log and how it ended', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-3', _plan());
    expect(_key('agent-panel'), findsNothing, reason: 'no agent has run');
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(
        item: 'R-3',
        path: '/state/logs/R-3.log',
        reset: true,
        lines: ['■ done · 3 turns'],
        last: AgentRunEndDto(
          exitCode: 0,
          reason: 'exited with code 0',
          outcome: 'handed over as review',
          sessionId: 's-1',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Agent · last run'), findsOneWidget);
    expect(find.text('■ done · 3 turns'), findsNothing, reason: 'an ended run starts collapsed');
    await tester.tap(_key('agent-log-toggle'));
    await tester.pump();
    expect(find.text('■ done · 3 turns'), findsOneWidget);
    expect(find.text('Last run · exited with code 0 · handed over as review · claude --resume s-1'), findsOneWidget);
  });

  testWidgets('the live log stays at the end and pauses while the reader scrolls up', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-1', _plan(running: true));
    AgentLogUpdateDto lines(int from, int count, {bool reset = false}) => AgentLogUpdateDto(
      item: 'R-1',
      path: '/l',
      running: true,
      reset: reset,
      lines: [for (var i = from; i < from + count; i++) 'line $i'],
    );
    ScrollPosition position() => tester
        .state<ScrollableState>(find.descendant(of: _key('agent-log'), matching: find.byType(Scrollable)))
        .position;

    api.agentLogUpdates.add(lines(0, 100, reset: true));
    await tester.pumpAndSettle();
    expect(position().pixels, position().maxScrollExtent);
    expect(position().maxScrollExtent, greaterThan(0));

    api.agentLogUpdates.add(lines(100, 20));
    await tester.pumpAndSettle();
    expect(position().pixels, position().maxScrollExtent, reason: 'follows new lines');

    await tester.drag(_key('agent-log'), const Offset(0, 300));
    await tester.pumpAndSettle();
    final paused = position().pixels;
    expect(paused, lessThan(position().maxScrollExtent));
    expect(_key('agent-log-follow'), findsOneWidget);
    api.agentLogUpdates.add(lines(120, 20));
    await tester.pumpAndSettle();
    expect(position().pixels, paused, reason: 'paused while scrolled up');

    await tester.tap(_key('agent-log-follow'));
    await tester.pumpAndSettle();
    expect(position().pixels, position().maxScrollExtent);
    expect(_key('agent-log-follow'), findsNothing);
  });

  group('AgentLogController', () {
    test('appends updates, replaces them on reset and keeps at most maxLines', () async {
      final api = FakeBacklogApi(_items());
      final controller = AgentLogController(api, 'R-1', maxLines: 3)..start();
      await Future<void>.delayed(Duration.zero);
      expect(api.followedLogs, ['R-1']);
      expect((controller.loaded, controller.hasLog), (false, false));

      api.agentLogUpdates.add(
        const AgentLogUpdateDto(item: 'R-1', path: '/a', running: true, reset: true, lines: ['a', 'b']),
      );
      api.agentLogUpdates.add(const AgentLogUpdateDto(item: 'R-1', path: '/a', running: true, lines: ['c', 'd']));
      api.agentLogUpdates.add(const AgentLogUpdateDto(item: 'R-2', path: '/x', lines: ['other item']));
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, ['b', 'c', 'd']);
      expect((controller.dropped, controller.running, controller.hasLog), (1, true, true));

      api.agentLogUpdates.add(
        const AgentLogUpdateDto(
          item: 'R-1',
          path: '/b',
          reset: true,
          lines: ['new'],
          last: AgentRunEndDto(exitCode: 1),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, ['new']);
      expect((controller.dropped, controller.running, controller.path, controller.last!.exitCode), (0, false, '/b', 1));

      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(api.followedLogs, isEmpty, reason: 'disposing stops following');
    });
  });
}

final class _NoDispatchApi implements BacklogApi {
  _NoDispatchApi(this._inner);

  final BacklogApi _inner;

  @override
  Stream<BacklogChangeEvent> changes() => _inner.changes();

  @override
  Future<DispatchDto> dispatch() => Future.error(const BacklogApiException(404, 'not_found', 'No such endpoint.'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
