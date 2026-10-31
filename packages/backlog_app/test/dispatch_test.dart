import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
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

  testWidgets('a running agent shows where and since when, its log and a Stop button', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-1', _plan(running: true));
    expect(find.text('w1 · R-1'), findsOneWidget);
    expect(find.textContaining('Agent claude in w1 since'), findsOneWidget);
    expect(find.textContaining('agent/R-1'), findsWidgets);

    api.log = const AgentLogDto(item: 'R-1', path: '/state/logs/R-1.log', running: true, lines: ['hello', 'world']);
    await tester.tap(find.text('Log'));
    await tester.pump();
    await tester.pump();
    expect(find.text('hello\nworld'), findsOneWidget);
    await tester.tap(find.text('Hide log'));
    await tester.pump();

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
