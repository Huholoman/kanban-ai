import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/dashboard/application/dashboard_controller.dart';
import 'package:backlog_app/features/dashboard/application/project_digest.dart';
import 'package:backlog_app/features/dashboard/presentation/dashboard_page.dart';
import 'package:backlog_app/features/item/presentation/item_page.dart';
import 'package:backlog_app/features/projects/application/project_memory.dart';
import 'package:backlog_app/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _now = DateTime.now().toUtc();

ItemDto _planned(
  String id, {
  String? milestone,
  String priority = 'p2',
  String status = 'todo',
  bool expired = false,
}) => ItemDto(
  id: id,
  title: 'Item $id',
  type: 'task',
  status: status,
  category: status == 'done' ? StatusCategoryDto.done : StatusCategoryDto.open,
  priority: priority,
  milestone: milestone,
  claim: expired
      ? ClaimDto(item: id, agent: 'w1', claimedAt: _now, heartbeatAt: _now, expiresAt: _now, expired: true)
      : null,
);

AgentRunDto _run(String item) => AgentRunDto(
  item: item,
  worktree: 'w1',
  pid: 7,
  startedAt: _now,
  log: '/logs/$item.log',
  agent: 'claude',
  branch: 'agent/$item',
);

DispatchDto _plan({
  List<AgentRunDto> runs = const [],
  List<HeldItemDto> held = const [],
  List<ProblemItemDto> problems = const [],
}) => DispatchDto(
  configured: true,
  mode: 'manual',
  maxAgents: 2,
  running: runs.length,
  capacity: 2 - runs.length,
  runs: runs,
  held: held,
  problems: problems,
  worktrees: const [DispatchWorktreeDto(name: 'w2', path: '/w/w2', busy: false, unavailable: 'uncommitted changes')],
);

CommentDto _question(String text) => CommentDto(author: 'w1', at: _now, text: text, question: true);

/// Project a: a question on A-1, A-2 in review, A-3 held. Project b: B-1
/// with an agent running.
FakeProjectsApi _projects() {
  final a = FakeBacklogApi([
    item('A-1', status: 'in-progress', needsHuman: true),
    item('A-2', status: 'review', review: 'changes', reviewFindings: 2),
    item('A-3', ready: true),
  ])..discussions['A-1'] = [_question('CSV or JSON?')];
  a
    ..plan = _plan(
      held: const [HeldItemDto(item: 'A-3', title: 'Item A-3', reason: 'the agent ended without finishing')],
    )
    ..actions = const [
      ActionDto(name: 'Merge', kind: 'builtin', statuses: ['review']),
    ];
  final b = FakeBacklogApi([item('B-1', status: 'in-progress')])..plan = _plan(runs: [_run('B-1')]);
  return FakeProjectsApi({'a': a, 'b': b});
}

void main() {
  group('ProjectDigest', () {
    const workflow = WorkflowDto(
      statuses: [
        StatusDto(id: 'todo', category: StatusCategoryDto.open),
        StatusDto(id: 'done', category: StatusCategoryDto.done),
      ],
      priorities: ['p0', 'p1', 'p2'],
      types: ['task', 'epic'],
      milestones: [
        MilestoneDto(id: 'v0.1'),
        MilestoneDto(id: 'v0.2'),
        MilestoneDto(id: 'later'),
      ],
      defaultStatus: 'todo',
      defaultPriority: 'p2',
      defaultType: 'task',
    );

    test('counts questions, approvals, problems and held items as needing a person', () {
      final digest = ProjectDigest(
        items: [
          item('T-1', needsHuman: true),
          item('T-2', status: 'review'),
          item('T-3', status: 'done', needsHuman: true),
          _planned('T-4', expired: true),
        ],
        plan: _plan(
          held: const [HeldItemDto(item: 'T-5', title: 'T', reason: 'stopped')],
          problems: const [
            ProblemItemDto(item: 'T-6', title: 'T', problems: ['opening its pull request failed: no remote']),
          ],
        ),
        lint: const [
          LintIssueDto(severity: 'error', code: 'x', message: 'broken'),
          LintIssueDto(severity: 'warning', code: 'y', message: 'odd'),
        ],
      );
      expect(digest.waitingForAnswer.map((i) => i.id), ['T-1'], reason: 'finished items wait for nobody');
      expect(digest.toApprove.map((i) => i.id), ['T-2']);
      expect(digest.problems.map((p) => p.item), ['T-6']);
      expect(digest.needsMe, 4);
      expect(digest.expiredClaims.map((i) => i.id), ['T-4']);
      expect((digest.lintErrors, digest.lintWarnings), (1, 1));
      expect(digest.unavailableWorktrees.map((w) => w.name), ['w2']);
    });

    test('an epic\'s agent works on the children its worktree holds', () {
      final digest = ProjectDigest(
        items: [
          item('E-1', type: 'epic', status: 'in-progress', claimedBy: 'w1'),
          item('C-1', status: 'in-progress', parent: 'E-1', claimedBy: 'w1'),
          item('C-2', parent: 'E-1', claimedBy: 'w2'),
          item('C-3', status: 'done', parent: 'E-1', claimedBy: 'w1'),
        ],
        plan: _plan(runs: [_run('E-1')]),
      );
      expect(digest.workedOnBy(digest.runs.single).map((i) => i.id), ['C-1']);
    });

    test('milestone progress and the urgent work of the current milestone', () {
      final digest = ProjectDigest(
        workflow: workflow,
        items: [
          _planned('V-1', milestone: 'v0.1', status: 'done'),
          _planned('V-2', milestone: 'v0.2', priority: 'p0'),
          _planned('V-3', milestone: 'v0.2', status: 'done'),
          _planned('V-4', milestone: 'v0.2', priority: 'p2'),
          _planned('V-5', milestone: 'later', priority: 'p0'),
        ],
      );
      expect(
        [for (final m in digest.milestones) '${m.milestone.id} ${m.done}/${m.total}'],
        ['v0.1 1/1', 'v0.2 1/3', 'later 0/1'],
      );
      expect(digest.currentMilestone?.id, 'v0.2', reason: 'v0.1 is finished, later is the parking lot');
      expect(digest.urgent.map((i) => i.id), ['V-2']);
    });
  });

  group('DashboardController', () {
    Future<(DashboardController, FakeProjectsApi)> started() async {
      final api = _projects();
      final projects = ProjectsController(api, memory: InMemoryProjectMemory());
      await projects.start();
      final dashboard = DashboardController(projects, refreshDelay: Duration.zero);
      await dashboard.refresh();
      addTearDown(dashboard.dispose);
      return (dashboard, api);
    }

    test('watches every project and reads the open questions', () async {
      final (dashboard, api) = await started();
      expect(dashboard.digests.map((d) => d.project?.id), ['a', 'b']);
      expect(dashboard.needsMe, 3);
      expect(dashboard.digests.first.questions['A-1']?.text, 'CSV or JSON?');
      expect(dashboard.digests.last.runs.map((r) => r.item), ['B-1']);
      expect(api.backlogs['b']!.listening, isTrue, reason: 'live although project a is open');

      dashboard.showOnly('b');
      expect(dashboard.shown.map((d) => d.project?.id), ['b']);
      expect(dashboard.needsMe, 3, reason: 'the badge counts every project');
    });

    test('an answer goes into the discussion and the question is gone', () async {
      final (dashboard, api) = await started();
      final a = dashboard.digests.first;
      expect(await dashboard.answer(a, 'A-1', 'CSV.'), isTrue);
      expect(api.backlogs['a']!.discussions['A-1']!.last.text, 'CSV.');
      expect(dashboard.digests.first.waitingForAnswer, isEmpty);
      expect(dashboard.needsMe, 2);
    });

    test('reloads a project when it changes', () async {
      final (dashboard, api) = await started();
      api.backlogs['b']!.externalChange(item('B-2', needsHuman: true));
      await pumpEventQueue();
      expect(dashboard.needsMe, 4);
    });
  });

  group('DashboardPage', () {
    Future<FakeProjectsApi> pumpApp(WidgetTester tester, {double width = 1400}) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _projects();
      await tester.pumpWidget(BacklogApp(projects: api, initialRoute: '/p/a', memory: InMemoryProjectMemory()));
      await tester.pumpAndSettle();
      return api;
    }

    String title(WidgetTester tester) => tester.widget<MaterialApp>(find.byType(MaterialApp)).title ?? '';

    testWidgets('the navigation and the page title count what waits for you', (tester) async {
      await pumpApp(tester);
      expect(title(tester), '(3) Project a');
      expect(find.descendant(of: find.byKey(const ValueKey('dashboard-badge')), matching: find.text('3')), findsOne);
    });

    testWidgets('shows questions, approvals, held and running work of every project', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('open-dashboard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('a:question-A-1')), findsOneWidget);
      expect(find.text('CSV or JSON?'), findsOneWidget);
      expect(find.byKey(const ValueKey('a:approve-A-2')), findsOneWidget);
      expect(find.text('AI review: 2 findings'), findsOneWidget);
      expect(find.byKey(const ValueKey('action-A-2-Merge')), findsOneWidget);
      expect(find.text('the agent ended without finishing'), findsOneWidget);
      expect(find.byKey(const ValueKey('b:run-B-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('a:unavailable-w2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('b:unavailable-w2')),
        findsOneWidget,
        reason: 'same worktree name, two projects',
      );
      expect(find.text('Project b'), findsWidgets, reason: 'rows name their project');

      await tester.tap(find.byKey(const ValueKey('dashboard-project')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dashboard-project-b')).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('a:question-A-1')), findsNothing);
      expect(find.byKey(const ValueKey('b:run-B-1')), findsOneWidget);
    });

    testWidgets('answers a question, runs an action and stops an agent', (tester) async {
      final api = await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('open-dashboard')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('answer-A-1')), 'JSON.');
      await tester.tap(find.byKey(const ValueKey('send-A-1')));
      await tester.pumpAndSettle();
      expect(api.backlogs['a']!.discussions['A-1']!.last.text, 'JSON.');
      expect(find.byKey(const ValueKey('a:question-A-1')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('action-A-2-Merge')));
      await tester.pumpAndSettle();
      expect(api.backlogs['a']!.actionsRun, ['A-2 Merge']);

      await tester.tap(find.byKey(const ValueKey('stop-B-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Stop').last);
      await tester.pumpAndSettle();
      expect(api.backlogs['b']!.stopped, ['B-1']);
    });

    testWidgets('opens an item of another project with that project', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey('open-dashboard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('b:run-B-1')));
      await tester.pumpAndSettle();
      expect(find.byType(ItemPage), findsOneWidget);
      expect(find.text('Item B-1'), findsWidgets);
      expect(
        find.byKey(const ValueKey('a:question-A-1')),
        findsNothing,
        reason: 'the item is a page over the dashboard',
      );
    });

    testWidgets('on a phone the sections are one column, Needs you first', (tester) async {
      await pumpApp(tester, width: 400);
      await tester.tap(find.byKey(const ValueKey('bottom-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-dashboard')));
      await tester.pumpAndSettle();
      final needsYou = tester.getTopLeft(find.byKey(const ValueKey('needs-you')));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('running')),
        200,
        scrollable: find.descendant(of: find.byType(DashboardPage), matching: find.byType(Scrollable)).first,
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('running'))).dx, needsYou.dx, reason: 'one column');
    });
  });
}
