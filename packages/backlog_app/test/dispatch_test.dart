import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/app_scope.dart';
import 'package:backlog_app/features/board/presentation/item_card.dart';
import 'package:backlog_app/features/dispatch/application/agent_log_controller.dart';
import 'package:backlog_app/features/dispatch/application/dispatch_controller.dart';
import 'package:backlog_app/features/dispatch/presentation/action_buttons.dart';
import 'package:backlog_app/features/dispatch/presentation/ball_badge.dart';
import 'package:backlog_app/features/dispatch/presentation/dispatch_overview.dart';
import 'package:backlog_app/features/dispatch/presentation/dispatch_scope.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/shared/tokens.dart';
import 'package:backlog_app/shared/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _started = DateTime.utc(2026, 10, 31, 12);

DispatchDto _plan({
  bool running = false,
  bool free = true,
  List<HeldItemDto> held = const [],
  List<HeldItemDto> waiting = const [],
  List<AgentSessionDto> sessions = const [],
  List<QueuedStartDto> queue = const [],
}) => DispatchDto(
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
  assignments: free
      ? [
          DispatchAssignmentDto(
            item: 'R-2',
            title: 'Item R-2',
            worktree: 'w2',
            resume: sessions.any((s) => s.item == 'R-2') ? 'sess-R-2' : null,
          ),
        ]
      : const [],
  held: held,
  waiting: [for (final item in waiting) item.item],
  waitingReasons: waiting,
  sessions: sessions,
  queue: queue,
);

QueuedStartDto _queued(String item, {int position = 1}) => QueuedStartDto(
  item: item,
  title: 'Item $item',
  kind: 'agent',
  since: _started,
  reason: 'no free worktree',
  position: position,
);

List<ItemDto> _items() => [
  item('R-1', status: 'in-progress'),
  item('R-2', ready: true),
  item('R-3', ready: true),
  item('B-1', status: 'backlog'),
  item('E-1', type: 'epic', children: const Progress(0, 2)),
  item('E-2', type: 'epic', children: const Progress(0, 1)),
  item('T-1', parent: 'E-1', ready: true),
  item('T-9', parent: 'E-2'),
];

const _epicCheck = EpicDto(
  epic: 'E-1',
  title: 'Item E-1',
  branch: 'agent/E-1',
  verdict: 'warning',
  warnings: ['T-2 waits for X-1 (todo) outside the epic; the agent stops there and asks.'],
  next: 'T-1',
  members: [
    EpicMemberDto(id: 'T-1', title: 'Item T-1', status: 'todo', state: 'to-do'),
    EpicMemberDto(id: 'T-2', title: 'Item T-2', status: 'todo', state: 'to-do', waits: ['X-1 (todo)']),
  ],
);

Future<(FakeBacklogApi, DispatchController)> _pumpDetail(
  WidgetTester tester,
  String reference,
  DispatchDto plan, {
  List<ActionDto> actions = const [],
  List<ItemDto>? items,
  String? milestone,
}) async {
  tester.view.physicalSize = const Size(700, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = FakeBacklogApi(items ?? _items())
    ..plan = plan
    ..actions = actions;
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
                Expanded(
                  child: ItemDetailView(reference: reference, milestone: milestone),
                ),
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

Future<(FakeBacklogApi, DispatchController)> _pumpDetailWith(
  WidgetTester tester,
  String reference,
  DispatchDto plan, {
  List<ActionDto> actions = const [],
}) => _pumpDetail(tester, reference, plan, actions: actions);

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
      expect(controller.canStart(api.items_['R-2']!), isTrue, reason: 'no free worktree: the start is queued');

      api.dispatchChange(_plan(running: true, free: false, queue: [_queued('R-2')]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.canStart(api.items_['R-2']!), isFalse, reason: 'queued already');
      expect(controller.queuedFor('R-2')!.position, 1);
    });

    test('a start that cannot happen yet says it was queued; Cancel drops it', () async {
      final api = FakeBacklogApi(_items())
        ..plan = _plan(free: false)
        ..afterStart = _plan(free: false, queue: [_queued('R-2')]);
      final controller = DispatchController(api, refreshDelay: Duration.zero);
      addTearDown(controller.dispose);
      final notices = <String>[];
      controller.notices.listen(notices.add);
      await controller.start();
      await controller.startAgent('R-2');
      await controller.cancelQueued('R-2');
      await Future<void>.delayed(Duration.zero);
      expect(api.cancelled, ['R-2']);
      expect(controller.queuedFor('R-2'), isNull);
      expect(notices, [
        'Queued: Start agent for R-2 waits for no free worktree (position 1).',
        'Cancelled the queued start of R-2.',
      ]);
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

  testWidgets('a queued start shows in the detail with Cancel', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-2', _plan(free: false, queue: [_queued('R-2')]));
    expect(_key('start-agent'), findsNothing, reason: 'queued already');
    expect(find.text('Queued: Start agent waits for no free worktree · position 1'), findsOneWidget);
    await tester.tap(_key('cancel-queued'));
    await tester.pumpAndSettle();
    expect(api.cancelled, ['R-2']);
    expect(_key('start-queued'), findsNothing);
    expect(_key('start-agent'), findsOneWidget);
  });

  testWidgets('an item with a session continues it, or starts fresh', (tester) async {
    final (api, _) = await _pumpDetail(
      tester,
      'R-2',
      _plan(
        sessions: const [AgentSessionDto(item: 'R-2', session: 'sess-R-2', worktree: 'w2')],
      ),
    );
    expect(find.text('Continue agent'), findsOneWidget);
    expect(find.text('R-2 → w2 ↻'), findsOneWidget);
    await tester.tap(_key('start-fresh'));
    await tester.pumpAndSettle();
    expect(api.startedFresh, ['R-2']);
    await tester.tap(_key('start-agent'));
    await tester.pumpAndSettle();
    expect(api.started, ['R-2', 'R-2']);
    expect(api.startedFresh, ['R-2']);
  });

  group('Implement epic', () {
    final run = AgentRunDto(
      item: 'E-1',
      worktree: 'w1',
      pid: 8,
      startedAt: _started,
      log: '/state/logs/E-1.log',
      agent: 'claude',
      branch: 'agent/E-1',
      epic: true,
    );
    final implementing = DispatchDto(
      configured: true,
      mode: 'manual',
      agent: 'claude',
      maxAgents: 2,
      running: 1,
      capacity: 1,
      worktrees: [
        DispatchWorktreeDto(name: 'w1', path: '/w/w1', busy: true, claims: const ['E-1'], run: run),
        const DispatchWorktreeDto(name: 'w2', path: '/w/w2', busy: false),
      ],
      runs: [run],
      epics: const ['E-1'],
    );

    testWidgets('checks the epic, starts it after a confirmation and shows how far it is', (tester) async {
      expect(DispatchDto.fromJson(implementing.toJson()).toJson(), implementing.toJson());
      expect(EpicDto.fromJson(_epicCheck.toJson()).toJson(), _epicCheck.toJson());
      final (api, _) = await _pumpDetail(tester, 'E-1', _plan());
      api
        ..epics['E-1'] = _epicCheck
        ..afterStart = implementing;
      expect(_key('start-agent'), findsNothing, reason: 'an epic is not ready');
      await tester.tap(_key('implement-epic'));
      await tester.pumpAndSettle();
      expect(_key('epic-dialog'), findsOneWidget);
      expect(find.text('It can start, but the agent will probably stop and ask:'), findsOneWidget);
      expect(find.textContaining('T-2  Item T-2 (todo) · waits for X-1 (todo)'), findsOneWidget);
      expect(find.text('Start anyway'), findsOneWidget);

      await tester.tap(_key('epic-start'));
      await tester.pumpAndSettle();
      expect(api.startedEpics, ['E-1']);
      expect(_key('implement-epic'), findsNothing);
      expect(find.textContaining('Agent claude implements the epic in w1 since'), findsOneWidget);
      expect(_key('epic-progress'), findsOneWidget);
      expect(find.text('0 done · 0 handed over · 0 in progress · 2 to do'), findsOneWidget);
    });

    testWidgets('the run can be limited to a milestone, by default the board\'s', (tester) async {
      const progress = [
        EpicProgressDto(milestone: 'v0.2', settled: 0, total: 1),
        EpicProgressDto(milestone: 'v0.3', settled: 0, total: 1),
      ];
      final (api, _) = await _pumpDetail(tester, 'E-1', _plan(), milestone: 'v0.2');
      api
        ..epics['E-1'] = const EpicDto(
          epic: 'E-1',
          title: 'Item E-1',
          branch: 'agent/E-1',
          verdict: 'ok',
          next: 'T-1',
          members: [
            EpicMemberDto(id: 'T-1', title: 'Item T-1', status: 'todo', state: 'to-do', milestone: 'v0.2'),
            EpicMemberDto(id: 'T-2', title: 'Item T-2', status: 'todo', state: 'to-do', milestone: 'v0.3'),
          ],
          progress: progress,
        )
        ..scopedEpics['E-1@v0.2'] = const EpicDto(
          epic: 'E-1',
          title: 'Item E-1',
          branch: 'agent/E-1',
          verdict: 'ok',
          next: 'T-1',
          milestone: 'v0.2',
          skipped: ['T-2'],
          members: [
            EpicMemberDto(id: 'T-1', title: 'Item T-1', status: 'todo', state: 'to-do', milestone: 'v0.2'),
            EpicMemberDto(
              id: 'T-2',
              title: 'Item T-2',
              status: 'todo',
              state: 'to-do',
              milestone: 'v0.3',
              inScope: false,
            ),
          ],
          progress: progress,
        );
      expect(EpicDto.fromJson(api.scopedEpics['E-1@v0.2']!.toJson()).toJson(), api.scopedEpics['E-1@v0.2']!.toJson());
      await tester.tap(_key('implement-epic'));
      await tester.pumpAndSettle();
      ChoiceChip chip(String id) => tester.widget<ChoiceChip>(_key('epic-scope-$id'));
      expect(chip('v0.2').selected, isTrue);
      expect(find.text('1 item(s) of other milestones stay as they are: T-2.'), findsOneWidget);
      expect(find.text('v0.2 0/1 · v0.3 0/1'), findsOneWidget);
      expect(_key('epic-member-T-2'), findsNothing);
      expect(find.text('0 done · 0 handed over · 0 in progress · 1 to do'), findsOneWidget);

      await tester.tap(_key('epic-scope-all'));
      await tester.pumpAndSettle();
      expect(chip('all').selected, isTrue);
      expect(_key('epic-skipped'), findsNothing);
      expect(_key('epic-member-T-2'), findsOneWidget);

      await tester.tap(_key('epic-scope-v0.2'));
      await tester.pumpAndSettle();
      await tester.tap(_key('epic-start'));
      await tester.pumpAndSettle();
      expect(api.startedEpics, ['E-1@v0.2']);
    });

    testWidgets('items in the backlog are not taken; the dialog moves one to todo', (tester) async {
      final (api, _) = await _pumpDetail(tester, 'E-1', _plan());
      api.epics['E-1'] = const EpicDto(
        epic: 'E-1',
        title: 'Item E-1',
        branch: 'agent/E-1',
        verdict: 'ok',
        next: 'T-1',
        members: [
          EpicMemberDto(id: 'T-1', title: 'Item T-1', status: 'todo', state: 'to-do'),
          EpicMemberDto(id: 'T-2', title: 'Item T-2', status: 'backlog', state: 'to-do', parked: true),
        ],
        parked: ['T-2'],
      );
      expect(EpicDto.fromJson(api.epics['E-1']!.toJson()).toJson(), api.epics['E-1']!.toJson());
      await tester.tap(_key('implement-epic'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 item(s) are not taken from the backlog: T-2.'), findsOneWidget);
      expect(find.text('0 done · 0 handed over · 0 in progress · 1 to do · 1 in backlog'), findsOneWidget);
      expect(find.textContaining('T-2  Item T-2 (backlog) · not taken'), findsOneWidget);

      api.items_['T-2'] = item('T-2', parent: 'E-1', status: 'backlog');
      await tester.tap(_key('epic-take-T-2'));
      await tester.pumpAndSettle();
      expect(api.updates.map((u) => '${u.$1} ${u.$2.changes.join(' ')}'), ['T-2 status=todo']);
      expect(_key('epic-dialog'), findsOneWidget, reason: 'it checks again');
    });

    testWidgets('an epic that cannot start says why and offers no start', (tester) async {
      final (api, _) = await _pumpDetail(tester, 'E-2', _plan());
      api.epics['E-2'] = const EpicDto(
        epic: 'E-2',
        title: 'Item E-2',
        branch: 'agent/E-2',
        verdict: 'forbidden',
        problems: ['E-2 depends on X-9, which does not exist.'],
      );
      await tester.tap(_key('implement-epic'));
      await tester.pumpAndSettle();
      expect(find.text('It cannot start:'), findsOneWidget);
      expect(find.text('✗ E-2 depends on X-9, which does not exist.'), findsOneWidget);
      expect(_key('epic-start'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.startedEpics, isEmpty);
    });
  });

  testWidgets('Start without a free worktree queues the start', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-3', _plan(free: false));
    expect(find.text('w2 · unavailable'), findsOneWidget);
    expect(_key('start-agent'), findsOneWidget, reason: 'the start waits in the queue');
    api.afterStart = _plan(free: false, queue: [_queued('R-3')]);
    await tester.tap(_key('start-agent'));
    await tester.pumpAndSettle();
    expect(find.text('Queued: Start agent waits for no free worktree · position 1'), findsOneWidget);
    expect(_key('start-agent'), findsNothing);
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

  testWidgets('manual mode: a ready item outside the proposals starts too', (tester) async {
    const plan = DispatchDto(
      configured: true,
      mode: 'manual',
      agent: 'claude',
      maxAgents: 2,
      capacity: 2,
      maxWorktrees: 2,
      spareWorktrees: 2,
      worktrees: [
        DispatchWorktreeDto(name: 'app-1', path: '/w/app-1', busy: false, created: true, isNew: true),
        DispatchWorktreeDto(name: 'app-2', path: '/w/app-2', busy: false, created: true, isNew: true),
      ],
      assignments: [
        DispatchAssignmentDto(item: 'R-2', title: 'Item R-2', worktree: 'app-1', newWorktree: true),
        DispatchAssignmentDto(item: 'X-9', title: 'Item X-9', worktree: 'app-2', newWorktree: true),
      ],
      waiting: ['R-3'],
    );
    final (api, _) = await _pumpDetail(tester, 'R-3', plan);
    expect(_key('start-agent'), findsOneWidget, reason: 'proposals of other items reserve nothing');
    expect(_key('agent-panel'), findsNothing, reason: 'it does not wait for anything');
    await tester.tap(_key('start-agent'));
    await tester.pumpAndSettle();
    expect(api.started, ['R-3']);
  });

  testWidgets('a running agent shows where and since when, its log and a Stop button', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-1', _plan(running: true));
    expect(find.text('w1 · R-1'), findsOneWidget);
    expect(find.textContaining('Agent claude in w1 since'), findsOneWidget);
    expect(find.textContaining('agent/R-1'), findsWidgets);
    expect(_key('ball-agent-R-1'), findsOneWidget, reason: 'the box says who has the ball');

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

    api.dispatchChange(
      _plan(
        waiting: const [HeldItemDto(item: 'R-1', title: 'Item R-1', reason: 'no free worktree')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waiting for an agent: no free worktree'), findsOneWidget);
    expect(find.text('R-1 waits: no free worktree'), findsOneWidget);
  });

  group('actions', () {
    const actions = [
      ActionDto(name: 'Fix comments', kind: 'prompt', statuses: ['in-progress'], agent: 'claude'),
      ActionDto(name: 'Tests', kind: 'command', statuses: ['in-progress', 'todo']),
      ActionDto(name: 'AI review', kind: 'prompt', onEnter: 'review', agent: 'claude', fresh: true),
    ];
    final testsRun = DispatchDto(
      configured: true,
      mode: 'manual',
      agent: 'claude',
      maxAgents: 2,
      capacity: 2,
      worktrees: [DispatchWorktreeDto(name: 'w1', path: '/w/w1', busy: true)],
      runs: [
        AgentRunDto(
          item: 'R-1',
          worktree: 'w1',
          pid: 9,
          startedAt: DateTime.utc(2026, 10, 31, 12),
          log: '/state/logs/R-1.log',
          agent: 'Tests',
          action: 'Tests',
          kind: 'command',
        ),
      ],
      pendingActions: [],
    );

    testWidgets('the detail has a button per action of its status; a run shows in the Agent box', (tester) async {
      final (api2, dispatch) = await _pumpDetailWith(tester, 'R-1', _plan(), actions: actions);
      expect(_key('action-Fix comments'), findsOneWidget);
      expect(_key('action-Tests'), findsOneWidget);
      expect(_key('action-AI review'), findsNothing, reason: 'offered in review only');

      api2.afterAction = testsRun;
      await tester.tap(_key('action-Tests'));
      await tester.pumpAndSettle();
      expect(api2.actionsRun, ['R-1 Tests']);
      expect(find.textContaining('Action "Tests" (command) in w1 since'), findsOneWidget);
      expect(_key('ball-agent-R-1'), findsOneWidget, reason: 'an action that is no AI review');
      final button = tester.widget<SecondaryButton>(_key('action-Fix comments'));
      expect(button.onPressed, isNotNull, reason: 'while something runs for the item it is queued');
      expect(dispatch.configured, isTrue);
    });

    testWidgets('a message written while an action runs shows that it waits, in the box and the discussion', (
      tester,
    ) async {
      final plan = DispatchDto(
        configured: true,
        mode: 'manual',
        agent: 'claude',
        maxAgents: 2,
        capacity: 1,
        runs: testsRun.runs,
        queuedReplies: const [
          HeldItemDto(item: 'R-1', title: 'Item R-1', reason: 'the agent continues after the action "Tests" ends'),
        ],
      );
      await _pumpDetailWith(tester, 'R-1', plan, actions: actions);
      expect(find.text('A message waits: the agent continues after the action "Tests" ends'), findsOneWidget);
      expect(find.text('Your message waits: the agent continues after the action "Tests" ends.'), findsOneWidget);
    });

    testWidgets('a queued on_enter action shows in the Agent box', (tester) async {
      final plan = DispatchDto(
        configured: true,
        mode: 'auto',
        agent: 'claude',
        maxAgents: 2,
        capacity: 2,
        pendingActions: [
          PendingActionDto(item: 'R-1', action: 'AI review', status: 'review', since: DateTime.utc(2026, 10, 31, 12)),
        ],
      );
      expect(DispatchDto.fromJson(plan.toJson()).toJson(), plan.toJson());
      await _pumpDetailWith(tester, 'R-1', plan, actions: actions);
      expect(_key('action-queued-AI review'), findsOneWidget);
      expect(_key('ball-queue-R-1'), findsOneWidget);
    });

    testWidgets('a card offers the actions of its status in a menu', (tester) async {
      final api = FakeBacklogApi(_items())
        ..plan = _plan()
        ..actions = actions;
      final dispatch = DispatchController(api, refreshDelay: Duration.zero);
      addTearDown(dispatch.dispose);
      await dispatch.start();
      final workflow = await api.workflow();
      await tester.pumpWidget(
        MaterialApp(
          theme: BoardTokens.light.toTheme(Brightness.light),
          home: Scaffold(
            body: DispatchScope(
              controller: dispatch,
              child: Column(
                children: [
                  ItemCard(
                    item: _items()[1],
                    workflow: workflow,
                    menu: CardActionsMenu(item: _items()[1], workflow: workflow),
                  ),
                  ItemCard(
                    item: _items()[3],
                    workflow: workflow,
                    menu: CardActionsMenu(item: _items()[3], workflow: workflow),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(_key('card-actions-B-1'), findsNothing, reason: 'backlog offers no actions');
      await tester.tap(_key('card-actions-R-2'));
      await tester.pumpAndSettle();
      expect(find.text('Fix comments'), findsNothing);
      await tester.tap(find.text('Tests'));
      await tester.pumpAndSettle();
      expect(api.actionsRun, ['R-2 Tests']);
    });

    test('runAction reports what started, and failures', () async {
      final api = FakeBacklogApi(_items())..plan = _plan();
      final dispatch = DispatchController(api, refreshDelay: Duration.zero);
      addTearDown(dispatch.dispose);
      final notices = <String>[];
      dispatch.notices.listen(notices.add);
      await dispatch.start();
      api.afterAction = testsRun;
      await dispatch.runAction('R-1', 'Tests');
      expect(dispatch.canRunAction('R-1'), isTrue, reason: 'a second one would be queued');
      api.failAction = const BacklogApiException(409, 'unavailable', 'The action "Tests" already runs for R-1.');
      await dispatch.runAction('R-1', 'Tests');
      await Future<void>.delayed(Duration.zero);
      expect(notices, ['Started "Tests" for R-1 in w1.', 'The action "Tests" already runs for R-1.']);
    });
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
    expect(find.text('Done · last run ended · handed over as review'), findsOneWidget);
    expect(_key('agent-problems'), findsNothing);
    expect(_key('agent-result'), findsNothing, reason: 'no final message');
    expect(find.text('■ done · 3 turns'), findsNothing, reason: 'an ended run starts collapsed');
    await tester.tap(_key('agent-log-toggle'));
    await tester.pump();
    expect(find.text('■ done · 3 turns'), findsOneWidget);
    expect(find.text('Last run · exited with code 0 · handed over as review · claude --resume s-1'), findsOneWidget);
  });

  testWidgets('a run that ended with problems needs you: the box lists them with the final message', (tester) async {
    final (api, _) = await _pumpDetail(tester, 'R-3', _plan());
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(
        item: 'R-3',
        path: '/state/logs/R-3.log',
        reset: true,
        lines: ['■ done'],
        last: AgentRunEndDto(
          exitCode: 0,
          outcome: 'handed over as review',
          result: 'Fixed it, but git push was denied.',
          problems: ['a tool call was denied: Bash(git push)'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Needs you: the last run ended with a problem'), findsOneWidget);
    expect(find.text('• a tool call was denied: Bash(git push)'), findsOneWidget);
    expect(find.text('Fixed it, but git push was denied.'), findsOneWidget);
  });

  testWidgets('a finished item needs nobody: the problems of its last run are history', (tester) async {
    final (api, _) = await _pumpDetail(
      tester,
      'R-3',
      _plan(),
      items: [for (final it in _items()) it.id == 'R-3' ? item('R-3', status: 'done') : it],
    );
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(
        item: 'R-3',
        path: '/state/logs/R-3.log',
        reset: true,
        lines: ['■ done'],
        last: AgentRunEndDto(
          exitCode: 0,
          outcome: 'handed over as review',
          result: 'Fixed it, but git push was denied.',
          problems: ['a tool call was denied: Bash(git push)'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Needs you'), findsNothing);
    expect(find.text('Last run ended · handed over as review · with a problem'), findsOneWidget);
    expect(find.text('• a tool call was denied: Bash(git push)'), findsOneWidget);
  });

  testWidgets('a card shows who has the ball: problems and holds wait for you', (tester) async {
    final api = FakeBacklogApi(_items())
      ..plan = DispatchDto(
        configured: true,
        mode: 'manual',
        problems: const [
          ProblemItemDto(item: 'R-2', title: 'Item R-2', problems: ['the agent exited with code 1']),
        ],
        held: const [HeldItemDto(item: 'R-3', title: 'Item R-3', reason: 'stopped by a person')],
      );
    final dispatch = DispatchController(api, refreshDelay: Duration.zero);
    addTearDown(dispatch.dispose);
    await dispatch.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: BoardTokens.light.toTheme(Brightness.light),
        home: Scaffold(
          body: DispatchScope(
            controller: dispatch,
            child: Column(
              children: [for (final item in _items()) ItemCard(item: item, menu: BallBadge.of(item, null))],
            ),
          ),
        ),
      ),
    );
    expect(_key('ball-you-R-2'), findsOneWidget);
    expect(_key('ball-you-R-3'), findsOneWidget);
    expect(_key('ball-you-R-1'), findsNothing);
    expect(_key('ball-you-B-1'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget); // R-2's problems, red
  });

  testWidgets('a child an epic\'s agent works on shows that agent and its live log', (tester) async {
    final plan = DispatchDto(
      configured: true,
      mode: 'manual',
      agent: 'claude',
      maxAgents: 2,
      capacity: 1,
      runs: [AgentRunDto(item: 'E-1', worktree: 'w1', pid: 3, startedAt: _started, log: '/l/E-1.log', agent: 'claude')],
    );
    final (api, _) = await _pumpDetail(
      tester,
      'C-1',
      plan,
      items: [
        item('E-1', type: 'epic', status: 'in-progress', claimedBy: 'w1'),
        item('C-1', status: 'in-progress', parent: 'E-1', claimedBy: 'w1'),
      ],
    );
    expect(find.textContaining('The agent of E-1 works on it: claude in w1 since'), findsOneWidget);
    expect(_key('stop-agent'), findsNothing, reason: 'the epic\'s agent is stopped on the epic');
    expect(api.followedLogs, ['E-1']);
    api.agentLogUpdates.add(
      const AgentLogUpdateDto(item: 'E-1', path: '/l/E-1.log', running: true, reset: true, lines: ['▸ Edit a.dart']),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('▸ Edit a.dart'), findsOneWidget);
    await tester.tap(_key('agent-open-runner'));
    await tester.pumpAndSettle();
    expect(find.text('Item E-1'), findsWidgets, reason: 'the epic opened');
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
