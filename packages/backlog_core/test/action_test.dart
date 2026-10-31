import 'dart:async';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const _root = '/work/backlog';

const _actions = '''
  actions:
    - name: Fix comments
      statuses: [review]
      prompt: "Fix the comments of PR {pr} ({status}, {base})"
    - name: AI review
      on_enter: review
      fresh: true
      prompt: "Review {branch}"
    - name: Tests
      statuses: [review]
      run: [sh, -c, "check {id} {pr} in {worktree}"]
    - name: Noop
      on_enter: done
      statuses: []
      run: noop
''';

Workflow _workflow({String repo = ''}) => parseWorkflowYaml('''
dispatcher:
  worktrees: [w1, w2]
  $repo
  agent: bot
  agents:
    bot:
      command: bot -p {prompt}
      output: claude-stream-json
      resume: --resume {session}
$_actions''');

Item _review(String id, {String? branch, String? pr}) =>
    item(id, status: 'review').copyWith(branch: () => branch, pr: () => pr);

DispatchPlan _plan(
  List<Item> items, {
  Workflow? workflow,
  List<Claim> claims = const [],
  DispatchConditions conditions = DispatchConditions.none,
}) => DispatchPlan.of(
  BacklogSnapshot.build(
    items: items,
    workflow: workflow ?? _workflow(),
    claims: claims,
    now: DateTime.utc(2026, 10, 29, 12),
  ),
  backlogRoot: _root,
  conditions: conditions,
)!;

AgentSession _session(String id, String worktree) => AgentSession(
  item: ItemId(id),
  id: 'sess-$id',
  worktree: worktree,
  agent: 'bot',
  startedAt: DateTime.utc(2026, 10, 29, 10),
  endedAt: DateTime.utc(2026, 10, 29, 11),
  reason: 'exited with code 0',
  outcome: 'it handed over as review, claim dropped',
);

void main() {
  _reviewLoopTests();

  test('every built-in action backlog.yaml accepts has an implementation', () {
    expect(BuiltInActions.standard.keys.toSet(), ActionDefinition.builtIns.keys.toSet());
    for (final MapEntry(:key, :value) in BuiltInActions.standard.entries) {
      expect(value.name, key);
    }
  });

  group('ActionState', () {
    final actions = _workflow().dispatcher!.actions;
    final now = DateTime.utc(2026, 10, 29, 12);
    BacklogSnapshot snapshot(Map<String, String> statuses) =>
        snapshotOf([for (final MapEntry(:key, :value) in statuses.entries) item(key, status: value)]);

    test('the first look and new items trigger nothing; a status change queues its on_enter actions once', () {
      var (state, queued) = const ActionState().observe(snapshot({'T-1': 'in-progress'}), actions, now);
      expect(queued, isEmpty, reason: 'the first evaluation only takes the statuses');
      expect(state.statuses, {ItemId('T-1'): 'in-progress'});

      (state, queued) = state.observe(snapshot({'T-1': 'in-progress', 'T-2': 'review'}), actions, now);
      expect(queued, isEmpty, reason: 'an item seen for the first time has no transition');

      (state, queued) = state.observe(snapshot({'T-1': 'review', 'T-2': 'review'}), actions, now);
      expect(queued.map((p) => '${p.item} ${p.action} ${p.from} → ${p.status}'), [
        'T-1 AI review in-progress → review',
      ]);
      expect(state.pending, hasLength(1));

      (state, queued) = state.observe(snapshot({'T-1': 'review', 'T-2': 'review'}), actions, now);
      expect(queued, isEmpty, reason: 'once per transition');
      expect(state.pending, hasLength(1));

      (state, queued) = state.observe(snapshot({'T-1': 'in-progress', 'T-2': 'done'}), actions, now);
      (state, queued) = state.observe(snapshot({'T-1': 'review', 'T-2': 'done'}), actions, now);
      expect(state.pending.map((p) => '${p.item} ${p.action}'), ['T-2 Noop', 'T-1 AI review'], reason: 'deduplicated');
    });

    test('survives a round trip through JSON', () {
      final state = ActionState(
        statuses: {ItemId('T-1'): 'review'},
        pending: [
          PendingAction(item: ItemId('T-1'), action: 'AI review', status: 'review', since: now, from: 'in-progress'),
        ],
        loops: {
          ItemId('T-2'): ReviewLoop(
            item: ItemId('T-2'),
            action: 'AI review',
            round: 1,
            phase: ReviewLoopPhase.fixing,
            since: now,
          ),
        },
      );
      final back = ActionState.fromJson(state.toJson());
      expect(back.statuses, state.statuses);
      expect(back.pending.single.toJson(), state.pending.single.toJson());
      expect(back.pending.single.from, 'in-progress');
      expect(back.loops[ItemId('T-2')]!.toJson(), state.loops[ItemId('T-2')]!.toJson());
      expect(back.withPending(const []).loops, hasLength(1), reason: 'loops survive other changes');
      expect(ActionState.fromJson(const {}).statuses, isNull);
    });
  });

  group('DispatchPlan.actionStart', () {
    test('lists the actions an item offers in its status', () {
      final plan = _plan([_review('T-1'), item('T-2')]);
      expect(plan.actionsFor(plan.snapshot[ItemId('T-1')]!).map((a) => a.name), ['Fix comments', 'AI review', 'Tests']);
      expect(plan.actionsFor(plan.snapshot[ItemId('T-2')]!), isEmpty);
    });

    test('a prompt action continues the item session in its worktree, without moving the item', () {
      final plan = _plan([
        _review('T-1', branch: 'feat/x', pr: '42'),
      ], conditions: DispatchConditions(sessions: {ItemId('T-1'): _session('T-1', 'w2')}));
      final start = plan.actionStart('T-1', 'Fix comments');
      final agent = start.agent!;
      expect(start.job, isNull);
      expect(agent.worktree.name, 'w2');
      expect(agent.resume!.id, 'sess-T-1');
      expect(agent.action!.name, 'Fix comments');
      expect(agent.command, ['bot', '-p', agent.prompt, '--resume', 'sess-T-1']);
      expect(agent.prompt, contains('started for the action "Fix comments" on backlog item T-1'));
      expect(agent.prompt, contains('it stays in status review'));
      expect(agent.prompt, contains('Since your last run: your last run exited with code 0'));
      expect(agent.prompt, contains('Fix the comments of PR 42 (review, main)'));
      expect(agent.key, 'T-1@w2+resume:Fix comments');
      expect(agent.prompt, contains('Never push.'));
    });

    test('with dispatcher.pr a prompt action publishes its commits with backlog pr', () {
      final plan = _plan([_review('T-1', pr: '42')], workflow: _workflow(repo: 'pr: {create: tea pulls create}'));
      final prompt = plan.actionStart('T-1', 'Fix comments').agent!.prompt;
      expect(prompt, contains('Never run `git push`: to publish your commits run `backlog pr T-1`'));
      expect(prompt, isNot(contains('Never push.')));
    });

    test('a fresh prompt action starts a new session where the item branch is checked out', () {
      final plan = _plan(
        [_review('T-1', branch: 'feat/x')],
        conditions: DispatchConditions(
          sessions: {ItemId('T-1'): _session('T-1', 'w1')},
          branches: {'w1': 'main', 'w2': 'feat/x'},
        ),
      );
      final agent = plan.actionStart('T-1', 'AI review').agent!;
      expect(agent.worktree.name, 'w2');
      expect(agent.resume, isNull);
      expect(agent.prompt, contains('Run `backlog show T-1` first'));
      expect(agent.prompt, contains('Review feat/x'));

      final noBranch = _plan([
        _review('T-1', branch: 'feat/x'),
      ], conditions: DispatchConditions(sessions: {ItemId('T-1'): _session('T-1', 'w2')}));
      expect(noBranch.actionStart('T-1', 'AI review').agent!.worktree.name, 'w2', reason: 'the session worktree');
    });

    test('a review action gets the built-in review task, changes nothing and finishes with backlog review', () {
      final workflow = parseWorkflowYaml('''
dispatcher:
  worktrees: [w1, w2]
  pr: {create: tea pulls create}
  actions:
    - {name: AI review, review: true, on_enter: review}
    - {name: Strict review, review: true, prompt: "Be strict about {base}."}
''');
      final plan = _plan(
        [_review('T-1', branch: 'feat/x', pr: 'https://git.example/o/r/pulls/7')],
        workflow: workflow,
        conditions: DispatchConditions(sessions: {ItemId('T-1'): _session('T-1', 'w1')}, branches: {'w2': 'feat/x'}),
      );
      final agent = plan.actionStart('T-1', 'AI review').agent!;
      expect(agent.resume, isNull, reason: 'always a new session');
      expect(agent.worktree.name, 'w2');
      final prompt = agent.prompt;
      expect(prompt, contains('started for the action "AI review" on backlog item T-1'));
      expect(
        prompt,
        contains('the changes of branch feat/x against main (`git log main..feat/x`, `git diff main...feat/x`)'),
      );
      expect(prompt, contains('proposed as pull request https://git.example/o/r/pulls/7'));
      expect(prompt, contains('CLAUDE.md, AGENTS.md'));
      expect(prompt, contains('Change nothing'));
      expect(prompt, contains('backlog review T-1 --ok'));
      expect(prompt, contains('backlog review T-1 --changes'));
      expect(prompt, contains('record your verdict with `backlog review`'));
      expect(prompt, contains('Never push.'));
      expect(prompt, isNot(contains('backlog pr T-1')));
      expect(prompt, isNot(contains('backlog comment T-1 "…"` and stop')));
      expect(prompt, isNot(contains('Also:')));
      expect(plan.actionStart('T-1', 'Strict review').agent!.prompt, contains('Also: Be strict about main.'));
    });

    test('a command runs in the worktree of the item branch, else in the primary clone', () {
      final inWorktree = _plan([
        _review('T-1', pr: '7'),
      ], conditions: const DispatchConditions(branches: {'w2': 'agent/T-1'})).actionStart('T-1', 'Tests').job!;
      expect(inWorktree.worktree, 'w2');
      expect(inWorktree.path, '/work/w2');
      expect(inWorktree.command, ['sh', '-c', 'check T-1 7 in w2']);
      expect(inWorktree.environment, containsPair('BACKLOG_AGENT', 'w2'));
      expect(inWorktree.environment, containsPair('KANBAN_AI_ACTION', 'Tests'));
      expect(inWorktree.environment, containsPair('GIT_EDITOR', 'true'));
      expect(inWorktree.environment, containsPair('GIT_SEQUENCE_EDITOR', 'true'));

      final inClone = _plan([
        _review('T-1'),
      ], workflow: _workflow(repo: 'repo: ../repo\n  max_worktrees: 3')).actionStart('T-1', 'Tests').job!;
      expect(inClone.worktree, isNull);
      expect(inClone.path, '/work/repo');
      expect(inClone.command, ['sh', '-c', 'check T-1  in ']);

      expect(
        () => _plan([_review('T-1')]).actionStart('T-1', 'Tests'),
        throwsA(isA<UnavailableException>().having((e) => e.message, 'message', contains('no free dispatcher'))),
      );
    });

    test('refuses unknown actions, actions not offered, and items something runs for', () {
      final plan = _plan(
        [_review('T-1'), item('T-2', status: 'in-progress')],
        conditions: DispatchConditions(
          runs: [
            AgentRun(
              item: ItemId('T-1'),
              worktree: 'w1',
              pid: 1,
              startedAt: DateTime.utc(2026),
              log: '/l',
              agent: 'Tests',
              action: 'Tests',
              kind: RunKind.command,
            ),
          ],
        ),
      );
      expect(() => plan.actionStart('T-1', 'Nope'), throwsA(isA<NotFoundException>()));
      expect(
        () => plan.actionStart('T-2', 'Tests'),
        throwsA(isA<InvalidInputException>().having((e) => e.message, 'message', contains('not offered'))),
      );
      expect(
        () => plan.actionStart('T-1', 'Fix comments'),
        throwsA(isA<UnavailableException>().having((e) => e.message, 'message', contains('"Tests" already runs'))),
      );
      expect(plan.worktrees.first.isBusy, isTrue, reason: 'a command makes its worktree busy');
      expect(
        plan.actionStart('T-2', 'Noop', trigger: ActionTrigger.onEnter).job!.path,
        _root,
        reason: 'hooks run whatever the buttons; a built-in without a worktree runs in the backlog',
      );
    });

    test('a ready item whose action runs is not assigned', () {
      final plan = _plan(
        [item('T-1')],
        conditions: DispatchConditions(
          runs: [
            AgentRun(
              item: ItemId('T-1'),
              worktree: 'repo',
              pid: 1,
              startedAt: DateTime.utc(2026),
              log: '/l',
              agent: 'Tests',
              action: 'Tests',
              kind: RunKind.command,
            ),
          ],
        ),
      );
      expect(plan.assignments, isEmpty);
    });
  });

  group('Dispatcher actions', () {
    late Backlog backlog;
    late _ActionLauncher launcher;
    late ActionStateStore store;
    late _MemoryRequests requests;
    late List<String> notes;

    Future<Dispatcher> start({String mode = 'manual', bool keepStore = false}) async {
      if (!keepStore) {
        (backlog, _) = await tempBacklog(
          config:
              '''
dispatcher:
  mode: $mode
  worktrees: [w1, w2]
  command: agent {id}
$_actions''',
        );
        // On disk, as in the server: times come back in UTC.
        store = FileActionStateStore(stateDir: '${backlog.root}/.state', project: 'demo');
        requests = _MemoryRequests();
        notes = [];
        launcher = _ActionLauncher(backlog);
      }
      final dispatcher = Dispatcher(
        snapshot: backlog.planning.snapshot,
        backlogRoot: backlog.root,
        launcher: launcher,
        clock: const SystemClock(),
        timer: (_, _) => Timer(const Duration(days: 1), () {}),
        onError: (error, _) => fail('$error'),
        actions: store,
        requests: requests,
        note: (item, text) async => notes.add('$item: $text'),
      );
      addTearDown(dispatcher.close);
      return dispatcher;
    }

    Future<void> setStatus(String id, String status) => backlog.items.update(id, [FieldChange.parse('status=$status')]);

    test('on_enter runs once per transition, in manual mode too, and not again after a restart', () async {
      var dispatcher = await start();
      await backlog.items.create(const NewItem(title: 'A', status: 'in-progress'));
      await dispatcher.evaluate();
      await setStatus('T-0001', 'review');
      await dispatcher.evaluate();
      expect(launcher.started, ['T-0001 AI review on_enter']);
      expect((await backlog.planning.snapshot())[ItemId('T-0001')]!.item.status, 'review');

      await launcher.finish('T-0001');
      await dispatcher.evaluate();
      expect(launcher.started, hasLength(1), reason: 'once per transition');

      await dispatcher.close();
      dispatcher = await start(keepStore: true);
      await dispatcher.evaluate();
      expect(launcher.started, hasLength(1), reason: 'a restart does not repeat it');

      await dispatcher.close();
      await setStatus('T-0001', 'in-progress');
      await setStatus('T-0001', 'done');
      dispatcher = await start(keepStore: true);
      await dispatcher.evaluate();
      expect(launcher.started, ['T-0001 AI review on_enter', 'T-0001 Noop on_enter'], reason: 'missed while down');
    });

    test('a hook waits while the item agent runs and is dropped when the item leaves the status', () async {
      final dispatcher = await start(mode: 'auto');
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await dispatcher.evaluate(); // auto: the agent starts (claims T-0001 under w1)
      expect(launcher.started, ['T-0001 agent']);
      await setStatus('T-0001', 'review');
      await dispatcher.evaluate();
      expect(launcher.started, hasLength(1), reason: 'the agent still runs');
      expect(dispatcher.current!.pending.map((p) => p.action), ['AI review']);

      await launcher.finish('T-0001');
      await dispatcher.evaluate();
      expect(launcher.started.last, 'T-0001 AI review on_enter');

      await backlog.items.create(const NewItem(title: 'B', status: 'in-progress'));
      await dispatcher.evaluate();
      await backlog.claims.claim('T-0002', 'someone');
      await setStatus('T-0002', 'review');
      await dispatcher.evaluate();
      expect(dispatcher.current!.pending.map((p) => '${p.item}'), ['T-0002'], reason: 'claimed: the prompt waits');
      await setStatus('T-0002', 'in-progress');
      await dispatcher.evaluate();
      expect(dispatcher.current!.pending, isEmpty);
      expect(launcher.started.where((s) => s.startsWith('T-0002 AI')), isEmpty);
    });

    test('runAction starts what a person asks for; requests of the CLI are picked up', () async {
      final dispatcher = await start();
      await backlog.items.create(const NewItem(title: 'A', status: 'review'));
      expect(await dispatcher.runAction('T-0001', 'Fix comments'), 'agent command in w1');
      expect(launcher.started, ['T-0001 Fix comments request']);
      final run = dispatcher.current!.runFor(ItemId('T-0001'))!;
      expect(run.action, 'Fix comments');
      await expectLater(dispatcher.runAction('T-0001', 'AI review'), throwsA(isA<UnavailableException>()));
      await launcher.finish('T-0001');

      await requests.add(ActionRequest(item: '0001', action: 'Tests', at: DateTime.now(), by: 'tobik'));
      await requests.add(ActionRequest(item: 'T-0001', action: 'Nope', at: DateTime.now(), by: 'tobik'));
      await dispatcher.evaluate();
      expect(notes, [
        startsWith('T-0001: The action "Tests" (requested by tobik) could not start: The action "Tests" runs in the'),
        startsWith('T-0001: The action "Nope" (requested by tobik) could not start: No action "Nope"'),
      ]);
    });
  });
}

/// Records what starts; agents claim like the real launcher, actions only
/// show up as runs until [finish].
final class _ActionLauncher extends AgentLauncher {
  _ActionLauncher(this.backlog);

  final Backlog backlog;
  final started = <String>[];
  final prompts = <String>[];
  final _runs = <ItemId, AgentRun>{};
  Map<ItemId, AgentSession> sessions = const {};

  @override
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async =>
      DispatchConditions(runs: [..._runs.values], sessions: sessions);

  @override
  Future<void> launch(DispatchAssignment assignment) async {
    final action = assignment.action;
    await backlog.claims.claim('${assignment.id}', assignment.agent, force: action != null, mirror: action == null);
    started.add(
      assignment.fix != null
          ? '${assignment.id} fix ${assignment.fix!.round}${assignment.resume == null ? '' : ' resumed'}'
          : action == null
          ? '${assignment.id} agent'
          : '${assignment.id} ${action.name} ${assignment.trigger.id}',
    );
    prompts.add(assignment.prompt);
    _runs[assignment.id] = AgentRun(
      item: assignment.id,
      worktree: assignment.agent,
      pid: 1,
      startedAt: DateTime.now(),
      log: '/log',
      agent: 'agent',
      action: action?.name,
    );
  }

  @override
  Future<void> runJob(ActionJob job) async {
    started.add('${job.id} ${job.action.name} ${job.trigger.id}');
    _runs[job.id] = AgentRun(
      item: job.id,
      worktree: job.worktree ?? 'repo',
      pid: 1,
      startedAt: DateTime.now(),
      log: '/log',
      agent: job.action.name,
      action: job.action.name,
      kind: job.command == null ? RunKind.builtIn : RunKind.command,
    );
  }

  Future<void> finish(String id) async {
    final run = _runs.remove(ItemId(id))!;
    await backlog.claims.drop(id, run.worktree);
  }
}

void _reviewLoopTests() {
  group('Review loop (auto_fix)', () {
    late Backlog backlog;
    late FixedClock clock;
    late _ActionLauncher launcher;
    late List<String> notes;
    late Dispatcher dispatcher;

    Future<String> git(List<String> args) async {
      final result = await Process.run('git', [
        '-c',
        'user.name=T',
        '-c',
        'user.email=t@example.com',
        ...args,
      ], workingDirectory: backlog.root);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}'.trim();
    }

    /// A new commit on the item's branch; its id.
    Future<String> commit(String message) async {
      await git(['commit', '-q', '--allow-empty', '-m', message]);
      return git(['rev-parse', 'HEAD']);
    }

    Future<void> review(ReviewVerdict verdict, String commit, {String text = '1. Off by one.\n2. No test.'}) async {
      clock.advance(const Duration(minutes: 1));
      await backlog.items.comment('T-0001', author: 'w2', text: text, review: verdict, commit: commit.substring(0, 12));
    }

    Future<void> tick() async {
      clock.advance(const Duration(minutes: 1));
      await dispatcher.evaluate();
    }

    Future<void> setUpLoop({int autoFix = 2, String mode = 'manual', String status = 'in-progress'}) async {
      (backlog, clock) = await tempBacklog(
        config:
            '''
dispatcher:
  mode: $mode
  worktrees: [w1, w2]
  agent: bot
  agents:
    bot: {command: "bot -p {prompt}", output: claude-stream-json, resume: "--resume {session}"}
  actions:
    - {name: AI review, review: true, on_enter: review${autoFix == 0 ? '' : ', auto_fix: $autoFix'}}
''',
      );
      // The backlog folder is the code repository here: branch heads for stale reviews.
      await git(['init', '-q', '-b', 'main']);
      await git(['commit', '-q', '--allow-empty', '-m', 'init']);
      await git(['switch', '-q', '-c', 'agent/T-0001']);
      notes = [];
      launcher = _ActionLauncher(backlog);
      dispatcher = Dispatcher(
        snapshot: backlog.planning.snapshot,
        backlogRoot: backlog.root,
        launcher: launcher,
        clock: clock,
        timer: (_, _) => Timer(const Duration(days: 1), () {}),
        onError: (error, _) => fail('$error'),
        actions: FileActionStateStore(stateDir: '${backlog.root}/.state', project: 'demo'),
        note: (item, text) async => notes.add(text),
      );
      addTearDown(dispatcher.close);
      await backlog.items.create(NewItem(title: 'A', status: status));
      await backlog.items.update('T-0001', [FieldChange.parse('branch=agent/T-0001')]);
      launcher.sessions = {
        ItemId('T-0001'): AgentSession(
          item: ItemId('T-0001'),
          id: 'sess-1',
          worktree: 'w1',
          agent: 'bot',
          startedAt: clock.now(),
          endedAt: clock.now(),
        ),
      };
      await dispatcher.evaluate();
    }

    test('changes wake the item agent in its session; its new commits are reviewed again; then a person', () async {
      await setUpLoop();
      final first = await commit('Work');
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await tick();
      expect(launcher.started, ['T-0001 AI review on_enter']);
      expect(dispatcher.current!.reviewOf(dispatcher.current!.snapshot[ItemId('T-0001')]!), ReviewState.running);

      await review(ReviewVerdict.changes, first);
      await tick();
      expect(launcher.started, hasLength(1), reason: 'the review still runs');
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 fix 1 resumed');
      final prompt = launcher.prompts.last;
      expect(prompt, contains('An AI review of your work asks for changes (automatic fix round 1 of 2)'));
      expect(prompt, contains('1. Off by one.\n2. No test.'));
      expect(prompt, contains('The review by w2 (of commit ${first.substring(0, 12)})'));
      expect(prompt, contains('run `backlog set T-0001 status=review` and stop'));
      expect(prompt, contains('Never push.'));
      expect(notes.last, contains('started the agent in w1 to fix them (automatic round 1 of 2)'));
      final item = (await backlog.planning.snapshot())[ItemId('T-0001')]!;
      expect((item.item.status, item.claim!.agent), ('review', 'w1'), reason: 'the agent took it in review');

      await tick();
      expect(launcher.started, hasLength(2), reason: 'nothing while the agent fixes');
      final second = await commit('Fix');
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 AI review on_enter', reason: 'new commits: review again');

      await review(ReviewVerdict.changes, second);
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 fix 2 resumed');
      final third = await commit('Fix again');
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 AI review on_enter');
      await review(ReviewVerdict.changes, third);
      await launcher.finish('T-0001');
      await tick();
      await tick();
      expect(launcher.started, hasLength(5), reason: 'two rounds, then it stops');
      expect(
        notes.last,
        'The AI review still asks for changes after 2 automatic fix rounds (auto_fix: 2); '
        'a person decides now.',
      );

      // A person asks for a review again: a new loop.
      await dispatcher.runAction('T-0001', 'AI review');
      await review(ReviewVerdict.ok, third, text: 'Fine.');
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 AI review request', reason: 'ok ends the loop');
      expect(launcher.started, hasLength(6));
    });

    test('a fix without new commits ends the loop; ok and a missing verdict end it too', () async {
      await setUpLoop(autoFix: 3, status: 'review');
      final first = await commit('Work');
      await dispatcher.runAction('T-0001', 'AI review');
      await review(ReviewVerdict.changes, first);
      await launcher.finish('T-0001');
      await tick();
      expect(launcher.started.last, 'T-0001 fix 1 resumed');
      await launcher.finish('T-0001');
      await tick();
      expect(notes.last, contains('without new commits; the automatic fixes stop here'));
      expect(launcher.started, hasLength(2));

      await dispatcher.runAction('T-0001', 'AI review');
      await launcher.finish('T-0001'); // ended without backlog review
      await tick();
      expect(launcher.started, hasLength(3));
    });

    test('entering the status again runs the review only for a new head; the button always', () async {
      await setUpLoop(autoFix: 0);
      final first = await commit('Work');
      Future<void> back() async {
        await backlog.items.update('T-0001', [FieldChange.parse('status=in-progress')]);
        await tick();
        await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
        await tick();
        await tick();
      }

      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await tick();
      expect(launcher.started, ['T-0001 AI review on_enter']);
      await review(ReviewVerdict.changes, first);
      await launcher.finish('T-0001');

      await back(); // e.g. a failed merge, nothing new on the branch
      expect(launcher.started, hasLength(1), reason: 'the review saw this head already');
      expect(dispatcher.current!.pending, isEmpty, reason: 'dropped, not waiting');

      await dispatcher.runAction('T-0001', 'AI review');
      expect(launcher.started.last, 'T-0001 AI review request', reason: 'a person may always ask');
      await review(ReviewVerdict.ok, first);
      await launcher.finish('T-0001');

      await commit('Fix');
      await back();
      expect(launcher.started.last, 'T-0001 AI review on_enter', reason: 'a new head is reviewed');
      expect(launcher.started, hasLength(3));
    });

    test('without auto_fix a review asking for changes wakes nobody, also in auto mode', () async {
      await setUpLoop(autoFix: 0, mode: 'auto', status: 'review');
      final first = await commit('Work');
      await dispatcher.runAction('T-0001', 'AI review');
      await review(ReviewVerdict.changes, first);
      await launcher.finish('T-0001');
      await tick();
      await tick();
      expect(launcher.started, ['T-0001 AI review request']);
      expect(dispatcher.current!.assignments, isEmpty, reason: 'a review is no reply for the agent');
      final planned = dispatcher.current!.snapshot[ItemId('T-0001')]!;
      expect((planned.review, dispatcher.current!.reviewOf(planned)), (ReviewState.changes, ReviewState.changes));

      // A person's comment is a reply; the resumed agent sees the review.
      clock.advance(const Duration(minutes: 1));
      await backlog.items.comment('T-0001', author: 'tobik', text: 'Please fix finding 1.');
      await tick();
      expect(launcher.started.last, 'T-0001 agent');
      expect(launcher.prompts.last, contains('### w2 · '));
      expect(launcher.prompts.last, contains('· review changes @'));
    });
  });
}

final class _MemoryRequests implements ActionRequests {
  final _waiting = <ActionRequest>[];

  @override
  Future<void> add(ActionRequest request) async => _waiting.add(request);

  @override
  Future<List<ActionRequest>> take() async {
    final taken = [..._waiting];
    _waiting.clear();
    return taken;
  }
}
