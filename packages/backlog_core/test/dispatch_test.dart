import 'dart:async';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const _root = '/work/backlog';

Workflow _workflow({String mode = 'manual', int? maxAgents, List<String> worktrees = const ['w1', 'w2', 'w3']}) =>
    parseWorkflowYaml('''
dispatcher:
  mode: $mode
  ${maxAgents == null ? '' : 'max_agents: $maxAgents'}
  worktrees: [${worktrees.join(', ')}]
  command: agent --item {id} --title "{title}" --in {path} --as {worktree} --backlog {backlog}
''');

/// A dispatcher whose agent can resume sessions (`--resume {session}`).
Workflow _resumingWorkflow({List<String> worktrees = const ['w1', 'w2', 'w3']}) => parseWorkflowYaml('''
dispatcher:
  worktrees: [${worktrees.join(', ')}]
  agent: bot
  agents:
    bot:
      command: bot -p {prompt}
      output: claude-stream-json
      resume: --resume {session}
  resume_prompt: "Again {id} in {worktree}: {news}"
''');

/// A resuming dispatcher that also creates worktrees from `../repo`.
Workflow _provisioningWorkflow() => parseWorkflowYaml('''
dispatcher:
  repo: ../repo
  max_worktrees: 3
  agent: bot
  agents:
    bot:
      command: bot -p {prompt}
      output: claude-stream-json
      resume: --resume {session}
''');

/// Conditions of [_provisioningWorkflow]: `repo-2` was created earlier,
/// `repo-3` may still be created.
DispatchConditions _provisioned({
  Map<ItemId, AgentSession> sessions = const {},
  Map<String, String> unavailable = const {},
}) => DispatchConditions(
  sessions: sessions,
  unavailable: unavailable,
  created: [WorktreeDefinition('repo-2', '/work/repo-2')],
  spare: [WorktreeDefinition('repo-3', '/work/repo-3')],
);

AgentSession _session(String id, String worktree, {String agent = 'bot'}) => AgentSession(
  item: ItemId(id),
  id: 'sess-$id',
  worktree: worktree,
  agent: agent,
  startedAt: DateTime.utc(2026, 10, 29, 10),
  endedAt: DateTime.utc(2026, 10, 29, 11),
  reason: 'exited with code 1',
  outcome: 'it left in-progress, released and held',
);

DispatchPlan _plan(
  List<Item> items, {
  Workflow? workflow,
  List<Claim> claims = const [],
  DateTime? now,
  DispatchConditions conditions = DispatchConditions.none,
}) => DispatchPlan.of(
  BacklogSnapshot.build(
    items: items,
    workflow: workflow ?? _workflow(),
    claims: claims,
    now: now ?? DateTime.utc(2026, 10, 29, 12),
  ),
  backlogRoot: _root,
  conditions: conditions,
)!;

Claim _claim(String id, String agent, {DateTime? at, Duration lease = const Duration(hours: 2)}) {
  final time = at ?? DateTime.utc(2026, 10, 29, 11);
  return Claim(itemId: ItemId(id), agent: agent, claimedAt: time, heartbeatAt: time, lease: lease);
}

void main() {
  group('DispatchPlan', () {
    test('no plan without a dispatcher section', () {
      expect(DispatchPlan.of(snapshotOf([item('T-1')]), backlogRoot: _root), isNull);
    });

    test('ready items in next order go to free worktrees in configured order', () {
      final plan = _plan([
        item('T-1', priority: 'p2'),
        item('T-2', priority: 'p0'),
        item('T-3', status: 'backlog'),
        item('T-4', dependsOn: ['T-3']),
        item('T-5', priority: 'p1'),
      ]);
      expect(plan.assignments.map((a) => a.key), ['T-2@w1', 'T-5@w2', 'T-1@w3']);
      expect(plan.waiting, isEmpty);
      expect(plan.running, 0);
      expect(plan.recheckAt, isNull);
      expect(plan.assignments.first.path, '/work/w1');
      expect(plan.assignments.first.command, [
        'agent',
        '--item',
        'T-2',
        '--title',
        'Item T-2',
        '--in',
        '/work/w1',
        '--as',
        'w1',
        '--backlog',
        _root,
      ]);
    });

    test('a live claim under a worktree name makes it busy and counts against the limit', () {
      final plan = _plan(
        [item('T-1', status: 'in-progress'), item('T-2'), item('T-3'), item('T-4')],
        workflow: _workflow(maxAgents: 2),
        claims: [_claim('T-1', 'w1')],
      );
      expect(plan.worktrees.map((w) => w.isBusy), [true, false, false]);
      expect(plan.running, 1);
      expect(plan.capacity, 1);
      expect(plan.assignments.map((a) => a.key), ['T-2@w2']);
      expect(plan.waiting.map((i) => '${i.id}'), ['T-3', 'T-4']);
      expect(plan.recheckAt, DateTime.utc(2026, 10, 29, 13)); // claimed 11:00 + 2 h
    });

    test('claims of other agents do not occupy worktrees; expired claims free them', () {
      final plan = _plan(
        [item('T-1', status: 'in-progress'), item('T-2', status: 'in-progress'), item('T-3')],
        workflow: _workflow(worktrees: ['w1']),
        claims: [
          _claim('T-1', 'someone'),
          _claim('T-2', 'w1', lease: const Duration(minutes: 30)),
        ],
      );
      expect(plan.worktrees.single.isBusy, isFalse);
      expect(plan.assignments.map((a) => a.key), ['T-3@w1']);
      expect(plan.recheckAt, DateTime.utc(2026, 10, 29, 13)); // only the live claim of "someone"
    });

    test('nothing to assign when every worktree is busy', () {
      final plan = _plan(
        [item('T-1', status: 'in-progress'), item('T-2')],
        workflow: _workflow(worktrees: ['w1']),
        claims: [_claim('T-1', 'w1')],
      );
      expect(plan.assignments, isEmpty);
      expect(plan.capacity, 0);
      expect(plan.waiting.map((i) => '${i.id}'), ['T-2']);
    });

    test('an item with a session of the agent continues it in its worktree, others keep that worktree free', () {
      final plan = _plan(
        [item('T-1', priority: 'p0'), item('T-2', priority: 'p1')],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(plan.assignments.map((a) => a.key), ['T-1@w2', 'T-2@w1+resume']);
      final resumed = plan.assignments.last;
      expect(resumed.resume!.id, 'sess-T-2');
      expect(resumed.command, [
        'bot',
        '-p',
        'Again T-2 in w1: your last run exited with code 1; it left in-progress, released and held. '
            'No new comments in the discussion.',
        '--resume',
        'sess-T-2',
      ]);
      expect(plan.assignments.first.command, hasLength(3), reason: 'a new session without --resume');
      expect(plan.resumableSession(ItemId('T-2'))!.worktree, 'w1');
    });

    test('a new session when the agent cannot resume or the session worktree is busy', () {
      final busy = _plan(
        [item('T-1', status: 'in-progress'), item('T-2')],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        claims: [_claim('T-1', 'w1')],
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(busy.assignments.map((a) => a.key), ['T-2@w2']);

      final otherAgent = _plan(
        [item('T-2')],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1', agent: 'claude')}),
      );
      expect(otherAgent.assignments.single.resume, isNull);

      final noResume = _plan([
        item('T-2'),
      ], conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1', agent: 'command')}));
      expect(noResume.assignments.single.resume, isNull, reason: 'a plain command cannot resume');
    });

    test('a manual start continues the session unless fresh', () {
      final plan = _plan(
        [item('T-1')],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(sessions: {ItemId('T-1'): _session('T-1', 'w2')}),
      );
      expect(plan.assignmentFor('T-1').key, 'T-1@w2+resume');
      expect(plan.assignmentFor('T-1', fresh: true).key, 'T-1@w1');
    });

    test('a reply of a person resumes the session first, whatever the status or hold', () {
      const reply =
          '## Discussion\n\n### w1 · 2026-10-29 10:30:00 UTC\n\nDone.\n\n'
          '### tobik · 2026-10-29 11:30:00 UTC\n\nWhy CSV?\n';
      final plan = _plan(
        [item('T-1', priority: 'p0'), item('T-2', status: 'review', body: reply)],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        conditions: DispatchConditions(
          sessions: {ItemId('T-2'): _session('T-2', 'w1')},
          held: {ItemId('T-2'): 'stopped'},
        ),
      );
      expect(plan.assignments.map((a) => a.key), ['T-2@w1+resume', 'T-1@w2']);
      expect(plan.held, isEmpty);
      final prompt = plan.assignments.first.prompt;
      expect(
        prompt,
        contains('New comments in the item\'s discussion since then:\n\n### tobik · 2026-10-29 11:30:00 UTC'),
      );
      expect(prompt, contains('Why CSV?'));
      expect(prompt, isNot(contains('Done.')), reason: 'the agent\'s own comments are not news');
      expect(plan.assignmentFor('T-2').key, 'T-2@w1+resume');
      expect(() => plan.assignmentFor('T-2', fresh: true), throwsA(isA<InvalidInputException>()));
    });

    test('a reply written while something runs for the item waits for the run to end', () {
      const body =
          '## Discussion\n\n### tobik · 2026-10-29 11:00:00 UTC\n\nBefore.\n\n'
          '### w1 · 2026-10-29 11:40:00 UTC\n\nOwn.\n\n'
          '### tobik · 2026-10-29 11:45:00 UTC · note\n\nJust a note.\n';
      AgentRun run(String id, {String? action}) => AgentRun(
        item: ItemId(id),
        worktree: 'w1',
        pid: 1,
        startedAt: DateTime.utc(2026, 10, 29, 11, 30),
        log: '/l',
        agent: 'bot',
        action: action,
      );
      DispatchPlan planWith(String body, List<AgentRun> runs) => _plan(
        [item('T-1', status: 'review', body: body), item('T-2', status: 'in-progress', body: body)],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(runs: runs, sessions: {ItemId('T-1'): _session('T-1', 'w1')}),
      );
      final runs = [run('T-1', action: 'AI review'), run('T-2')];
      expect(planWith(body, runs).queuedReplies, isEmpty, reason: 'older comments, own comments and notes');

      const reply = '$body\n### tobik · 2026-10-29 11:50:00 UTC\n\nWhy CSV?\n';
      final plan = planWith(reply, runs);
      expect(plan.queuedReplies.map((id, reason) => MapEntry('$id', reason)), {
        'T-1': 'the agent continues after the action "AI review" ends',
        'T-2': 'the agent reads it after its current run',
      });
      expect(plan.assignments, isEmpty, reason: 'one run per item');
      expect(planWith(reply, const []).queuedReplies, isEmpty, reason: 'nothing runs');
    });

    test('a note of a person does not wake the agent; a resumed agent sees it as context', () {
      const note = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC · note\n\nMaybe JSON later.\n';
      final quiet = _plan(
        [item('T-2', status: 'review', body: note)],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(quiet.assignments, isEmpty);
      expect(quiet.waiting, isEmpty);

      const both = '$note\n### tobik · 2026-10-29 11:40:00 UTC\n\nWhy CSV?\n';
      final woken = _plan(
        [item('T-2', status: 'review', body: both)],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(woken.assignments.single.key, 'T-2@w1+resume');
      final prompt = woken.assignments.single.prompt;
      expect(prompt, contains('### tobik · 2026-10-29 11:30:00 UTC · note\n\nMaybe JSON later.'));
      expect(prompt, contains('Why CSV?'));
      expect(prompt, contains('Comments marked "note" are context for you; they need no answer.'));
    });

    test('replies wait for the session worktree; own comments and old comments are no replies', () {
      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final busy = _plan(
        [item('T-1', status: 'in-progress'), item('T-2', status: 'review', body: reply)],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        claims: [_claim('T-1', 'w1')],
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(busy.assignments, isEmpty);
      expect(busy.waiting.map((i) => '${i.id}'), ['T-2']);
      expect(() => busy.assignmentFor('T-2'), throwsA(isA<UnavailableException>()));

      for (final body in [
        '## Discussion\n\n### w1 · 2026-10-29 11:30:00 UTC\n\nNote to self.\n',
        '## Discussion\n\n### tobik · 2026-10-29 09:30:00 UTC\n\nBefore the run.\n',
      ]) {
        final quiet = _plan(
          [item('T-2', status: 'review', body: body)],
          workflow: _resumingWorkflow(),
          conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
        );
        expect(quiet.assignments, isEmpty, reason: body);
      }
    });

    test('with worktrees on demand a session resumes in its created worktree, new work gets a new one', () {
      final plan = _plan(
        [item('T-1', priority: 'p0'), item('T-2', priority: 'p1')],
        workflow: _provisioningWorkflow(),
        conditions: _provisioned(sessions: {ItemId('T-2'): _session('T-2', 'repo-2')}),
      );
      expect(plan.assignments.map((a) => '${a.key}:${a.createFrom != null}'), [
        'T-1@repo-3:true',
        'T-2@repo-2+resume:false',
      ]);
      expect(plan.worktrees.map((w) => (w.name, w.created, w.isNew)), [
        ('repo-2', true, false),
        ('repo-3', true, true),
      ]);

      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final replied = _plan(
        [item('T-1', priority: 'p0'), item('T-2', status: 'review', body: reply)],
        workflow: _provisioningWorkflow(),
        conditions: _provisioned(sessions: {ItemId('T-2'): _session('T-2', 'repo-2')}),
      );
      expect(replied.assignments.map((a) => a.key), ['T-2@repo-2+resume', 'T-1@repo-3']);
      expect(replied.assignmentFor('T-2').key, 'T-2@repo-2+resume');
    });

    test('a reply never moves to a new worktree; it waits for its own', () {
      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final plan = _plan(
        [item('T-1', status: 'in-progress'), item('T-2', status: 'review', body: reply), item('T-3')],
        workflow: _provisioningWorkflow(),
        claims: [_claim('T-1', 'repo-2')],
        conditions: _provisioned(sessions: {ItemId('T-2'): _session('T-2', 'repo-2')}),
      );
      expect(plan.assignments.map((a) => '${a.key}:${a.createFrom != null}'), ['T-3@repo-3:true']);
      expect(plan.waiting.map((i) => '${i.id}'), ['T-2']);
      expect(() => plan.assignmentFor('T-2'), throwsA(isA<UnavailableException>()));

      // A ready item whose session worktree is busy starts a new session, in a new worktree.
      final ready = _plan(
        [item('T-1', status: 'in-progress'), item('T-2')],
        workflow: _provisioningWorkflow(),
        claims: [_claim('T-1', 'repo-2')],
        conditions: _provisioned(sessions: {ItemId('T-2'): _session('T-2', 'repo-2')}),
      );
      final start = ready.assignmentFor('T-2');
      expect((start.key, start.resume, start.createFrom), ('T-2@repo-3', null, '/work/repo'));
    });

    test('the worktree of an agent waiting for an answer is left to it; new work gets a new worktree', () {
      const asked = '## Discussion\n\n### repo-2 · 2026-10-29 10:30:00 UTC · question\n\nCSV or JSON?\n';
      final plan = _plan(
        [item('T-1', body: asked), item('T-3')],
        workflow: _provisioningWorkflow(),
        conditions: _provisioned(sessions: {ItemId('T-1'): _session('T-1', 'repo-2')}),
      );
      expect(plan.assignments.map((a) => '${a.key}:${a.createFrom != null}'), ['T-3@repo-3:true']);

      final listed = _plan(
        [item('T-1', body: asked.replaceAll('repo-2', 'w1')), item('T-3')],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        conditions: DispatchConditions(sessions: {ItemId('T-1'): _session('T-1', 'w1')}),
      );
      expect(listed.assignments.map((a) => a.key), ['T-3@w2']);
    });

    test('a session whose worktree is gone is forgotten: a new session, replies no longer resume', () {
      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final sessions = {ItemId('T-1'): _session('T-1', 'repo-5'), ItemId('T-2'): _session('T-2', 'repo-5')};
      final plan = _plan(
        [item('T-1'), item('T-2', status: 'review', body: reply)],
        workflow: _provisioningWorkflow(),
        conditions: _provisioned(sessions: sessions),
      );
      expect(plan.sessions, isEmpty);
      expect(plan.resumableSession(ItemId('T-1')), isNull);
      expect(plan.assignments.map((a) => a.key), ['T-1@repo-2']);
      expect(plan.waiting, isEmpty, reason: 'the reply on T-2 waits for a person to start it again');
      expect(() => plan.assignmentFor('T-2'), throwsA(isA<InvalidInputException>()));

      // A listed worktree that is missing is only unavailable: its reply waits.
      final listed = _plan(
        [item('T-2', status: 'review', body: reply)],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        conditions: DispatchConditions(
          sessions: {ItemId('T-2'): _session('T-2', 'w1')},
          unavailable: {'w1': 'missing folder'},
        ),
      );
      expect(listed.assignments, isEmpty);
      expect(listed.waiting.map((i) => '${i.id}'), ['T-2']);
    });

    test('a reply without a session to continue starts a new session where the item\'s branch is', () {
      const reply =
          '## Discussion\n\n### g-1 · 2026-10-29 09:00:00 UTC\n\nDone, in review.\n\n'
          '### tobik · 2026-10-29 11:30:00 UTC\n\nRebase pls.\n';
      // Worked on elsewhere: no session, no known start, but a branch and an assignee.
      final elsewhere = item(
        'T-2',
        status: 'review',
        body: reply,
      ).copyWith(branch: () => 'agent/T-2', assignee: () => 'g-1');
      final plan = _plan(
        [item('T-1', priority: 'p0'), elsewhere],
        workflow: _resumingWorkflow(),
        conditions: const DispatchConditions(branches: {'w2': 'agent/T-2'}),
      );
      expect(plan.assignments.map((a) => a.key), ['T-2@w2+reply', 'T-1@w1']);
      final start = plan.assignments.first;
      expect(start.resume, isNull);
      expect(plan.isReply(start), isTrue, reason: 'it starts in manual mode too');
      expect(plan.isReply(plan.assignments.last), isFalse);
      expect(start.prompt, startsWith('Again T-2 in w2: there is no earlier session of yours to continue'));
      expect(start.prompt, contains('### tobik · 2026-10-29 11:30:00 UTC\n\nRebase pls.'));
      expect(start.prompt, isNot(contains('Done, in review.')), reason: 'the assignee\'s own comments are not news');
      expect(plan.assignmentFor('T-2').key, 'T-2@w2+reply');
      expect(() => plan.assignmentFor('T-2', fresh: true), throwsA(isA<InvalidInputException>()));

      // A failed merge's comment of the dispatcher counts the same; a note does not.
      const merge = '## Discussion\n\n### kanban-ai · 2026-10-29 11:30:00 UTC\n\nThe merge failed: rebase.\n';
      final failed = _plan([elsewhere.copyWith(body: merge)], workflow: _resumingWorkflow());
      expect(failed.assignments.single.key, 'T-2@w1+reply');
      expect(failed.assignments.single.prompt, contains('The merge failed: rebase.'));
      final noted = _plan([
        elsewhere.copyWith(body: merge.replaceFirst('UTC', 'UTC · note')),
      ], workflow: _resumingWorkflow());
      expect(noted.assignments, isEmpty);

      // Without a branch, or not yet worked on (todo), nothing is known to continue.
      expect(_plan([elsewhere.copyWith(branch: () => null)], workflow: _resumingWorkflow()).assignments, isEmpty);
      expect(_plan([elsewhere.copyWith(status: 'backlog')], workflow: _resumingWorkflow()).assignments, isEmpty);
    });

    test('a new session for replies runs once: after its start the comments are old', () {
      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final t2 = item('T-2', status: 'review', body: reply).copyWith(branch: () => 'agent/T-2');
      // Its session ran in a worktree that is gone: the start is still known.
      final gone = _plan(
        [t2],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(
          sessions: {ItemId('T-2'): _session('T-2', 'w9')},
          starts: {ItemId('T-2'): (at: DateTime.utc(2026, 10, 29, 10), worktree: 'w9')},
        ),
      );
      expect(gone.assignments.single.key, 'T-2@w1+reply');

      // The new session started after the reply (its own comment is no reply either).
      final later = _plan(
        [t2.copyWith(body: '$reply\n### w1 · 2026-10-29 11:50:00 UTC\n\nRebased.\n')],
        workflow: _resumingWorkflow(),
        conditions: DispatchConditions(
          starts: {ItemId('T-2'): (at: DateTime.utc(2026, 10, 29, 11, 40), worktree: 'w1')},
        ),
      );
      expect(later.assignments, isEmpty);
      expect(later.waiting, isEmpty);
    });

    test('items that wait for an agent say why', () {
      const reply = '## Discussion\n\n### tobik · 2026-10-29 11:30:00 UTC\n\nWhy?\n';
      final plan = _plan(
        [
          item('T-1', status: 'in-progress'),
          item('T-2', status: 'review', body: reply),
          item('T-3', status: 'review', body: reply).copyWith(branch: () => 'agent/T-3'),
          item('T-4'),
        ],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        claims: [_claim('T-1', 'w1')],
        conditions: DispatchConditions(
          sessions: {ItemId('T-2'): _session('T-2', 'w1')},
          unavailable: {'w2': 'uncommitted changes (1 paths)'},
        ),
      );
      expect(plan.assignments, isEmpty);
      expect(plan.waiting.map((i) => '${i.id}'), ['T-2', 'T-3', 'T-4']);
      expect(plan.waitingReasons.map((id, reason) => MapEntry('$id', reason)), {
        'T-2': 'no free worktree',
        'T-3': 'no free worktree',
        'T-4': 'no free worktree',
      });

      final limited = _plan(
        [item('T-1', status: 'in-progress'), item('T-2', status: 'review', body: reply), item('T-4')],
        workflow: _resumingWorkflow(worktrees: ['w1', 'w2']),
        claims: [_claim('T-1', 'w1')],
        conditions: DispatchConditions(sessions: {ItemId('T-2'): _session('T-2', 'w1')}),
      );
      expect(limited.assignments.map((a) => a.key), ['T-4@w2']);
      expect(limited.waitingReasons.map((id, reason) => MapEntry('$id', reason)), {
        'T-2': 'the worktree w1 of its session is not free',
      });
    });

    test('manual mode: proposals reserve nothing, any ready item starts by hand while a slot is free', () {
      Workflow onDemand(String mode) => parseWorkflowYaml('''
dispatcher:
  mode: $mode
  repo: ../repo
  max_worktrees: 2
  max_agents: 2
  command: agent {id}
''');
      final items = [item('T-1', priority: 'p0'), item('T-2', priority: 'p1'), item('T-3', priority: 'p2')];
      final spare = DispatchConditions(
        spare: [WorktreeDefinition('repo-1', '/work/repo-1'), WorktreeDefinition('repo-2', '/work/repo-2')],
      );
      final plan = _plan(items, workflow: onDemand('manual'), conditions: spare);
      expect(plan.assignments.map((a) => a.key), ['T-1@repo-1', 'T-2@repo-2']);
      expect(plan.waiting.map((i) => '${i.id}'), ['T-3']);
      expect(plan.waitingReasons, isEmpty, reason: 'T-3 can start by hand');
      expect(plan.assignmentFor('T-3').key, 'T-3@repo-1');

      // Auto mode starts in order: T-3 really waits.
      final auto = _plan(items, workflow: onDemand('auto'), conditions: spare);
      expect(auto.assignments.map((a) => a.key), ['T-1@repo-1', 'T-2@repo-2']);
      expect(auto.waitingReasons.map((id, reason) => MapEntry('$id', reason)), {'T-3': 'no free worktree'});

      // All slots running: nothing can start, in manual mode either.
      final full = _plan(
        [...items, item('T-4', status: 'in-progress'), item('T-5', status: 'in-progress')],
        workflow: _workflow(maxAgents: 2),
        claims: [_claim('T-4', 'w1'), _claim('T-5', 'w2')],
      );
      expect(full.assignments, isEmpty);
      expect(full.waitingReasons.map((id, reason) => MapEntry('$id', reason)), {
        'T-1': 'max_agents (2) reached',
        'T-2': 'max_agents (2) reached',
        'T-3': 'max_agents (2) reached',
      });
      expect(() => full.assignmentFor('T-3'), throwsA(isA<UnavailableException>()));
    });

    test('sameDecisionAs compares assignments, waiting items and busy worktrees', () {
      final a = _plan([item('T-1')]);
      expect(a.sameDecisionAs(_plan([item('T-1')])), isTrue);
      expect(a.sameDecisionAs(_plan([item('T-1'), item('T-2')])), isFalse);
      expect(a.sameDecisionAs(null), isFalse);
    });
  });

  group('Dispatcher', () {
    late Backlog backlog;
    late FixedClock clock;
    late _FakeTimers timers;
    late _RecordingLauncher launcher;
    late List<Object> errors;

    Future<Dispatcher> start(
      String mode, {
      int? maxAgents,
      List<String> worktrees = const ['w1', 'w2'],
      bool resuming = false,
    }) async {
      final config =
          '''
dispatcher:
  mode: $mode
  ${maxAgents == null ? '' : 'max_agents: $maxAgents'}
  worktrees: [${worktrees.join(', ')}]
  ${resuming ? 'agent: bot\n  agents:\n    bot:\n      command: bot -p {prompt}\n      output: claude-stream-json\n      resume: --resume {session}' : 'command: agent {id}'}
''';
      (backlog, clock) = await tempBacklog(config: config);
      timers = _FakeTimers();
      launcher = _RecordingLauncher(backlog);
      errors = [];
      final dispatcher = Dispatcher(
        snapshot: backlog.planning.snapshot,
        backlogRoot: backlog.root,
        launcher: launcher,
        clock: clock,
        timer: timers.create,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(dispatcher.close);
      return dispatcher;
    }

    Future<void> todo(String title, {String priority = 'p2'}) =>
        backlog.items.create(NewItem(title: title, status: 'todo', priority: priority));

    test('auto mode launches each assignment once, then only new ones', () async {
      final dispatcher = await start('auto');
      launcher.claims = false;
      await todo('A');
      await todo('B', priority: 'p0');
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0002@w1', 'T-0001@w2']);

      await dispatcher.evaluate();
      expect(launcher.launched, hasLength(2), reason: 'an unchanged plan is not launched again');
      expect(errors, isEmpty);
    });

    test('a launcher that claims frees the plan of its items', () async {
      final dispatcher = await start('auto', maxAgents: 1);
      await todo('A');
      await todo('B');
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0001@w1']);
      expect((await backlog.planning.snapshot())[ItemId('T-0001')]!.claim!.agent, 'w1');

      final plan = await dispatcher.evaluate();
      expect(plan!.running, 1);
      expect(plan.assignments, isEmpty, reason: 'max_agents is reached');
      expect(plan.waiting.map((i) => '${i.id}'), ['T-0002']);

      await backlog.claims.complete('T-0001', agent: 'w1');
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0001@w1', 'T-0002@w1']);
    });

    test('manual mode only publishes the plan', () async {
      final dispatcher = await start('manual');
      final plans = <DispatchPlan?>[];
      dispatcher.plans.listen(plans.add);
      await todo('A');
      await dispatcher.evaluate();
      await dispatcher.evaluate();
      await Future<void>.delayed(Duration.zero);
      expect(launcher.launched, isEmpty);
      expect(plans, hasLength(1), reason: 'only changes are published');
      expect(dispatcher.current!.assignments.map((a) => a.key), ['T-0001@w1']);
    });

    test('manual mode wakes an agent a person replied to, and only that', () async {
      final dispatcher = await start('manual', resuming: true);
      launcher.claims = false;
      await todo('A');
      await backlog.items.create(NewItem(title: 'B', status: 'review'));
      launcher.given = DispatchConditions(sessions: {ItemId('T-0002'): _session('T-0002', 'w2')});
      await dispatcher.evaluate();
      expect(launcher.launched, isEmpty, reason: 'no reply yet; new work is only proposed');

      await backlog.items.comment('T-0002', author: 'tobik', text: 'Just context.', note: true);
      await backlog.items.comment('T-0002', author: 'w3', text: 'Review.', review: ReviewVerdict.changes);
      await dispatcher.evaluate();
      expect(launcher.launched, isEmpty, reason: 'notes and reviews wake nobody');

      await backlog.items.comment('T-0002', author: 'kanban-ai', text: 'The merge failed: rebase on main.');
      final plan = await dispatcher.evaluate();
      expect(plan!.assignments.map((a) => a.key), ['T-0002@w2+resume', 'T-0001@w1']);
      expect(launcher.launched, ['T-0002@w2+resume'], reason: 'T-0001 stays a proposal');
      await dispatcher.evaluate();
      expect(launcher.launched, hasLength(1), reason: 'launched once');
    });

    test('manual mode starts a new session for a reply on an item without one', () async {
      final dispatcher = await start('manual', resuming: true);
      await backlog.items.create(NewItem(title: 'B', status: 'review'));
      await backlog.items.update('T-0001', [FieldChange.parse('branch=agent/T-0001')]);
      launcher.given = const DispatchConditions(branches: {'w2': 'agent/T-0001'});
      await dispatcher.evaluate();
      expect(launcher.launched, isEmpty);

      await backlog.items.comment('T-0001', author: 'kanban-ai', text: 'The merge failed: rebase on main.');
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0001@w2+reply']);
      await dispatcher.evaluate();
      expect(launcher.launched, hasLength(1), reason: 'claimed: launched once');
      expect(errors, isEmpty);
    });

    test('changes are debounced into one evaluation', () async {
      final dispatcher = await start('auto');
      launcher.claims = false;
      await todo('A');
      dispatcher.notifyChanged();
      dispatcher.notifyChanged();
      expect(timers.pending.map((t) => t.delay), [dispatcher.debounce]);
      timers.fireAll();
      await dispatcher.evaluate(); // waits for the triggered one
      expect(launcher.launched, ['T-0001@w1']);
    });

    test('wakes up when a claim expires and the worktree frees up', () async {
      final dispatcher = await start('auto', worktrees: ['w1']);
      await todo('A');
      await todo('B');
      await backlog.claims.claim('T-0001', 'w1');
      await dispatcher.evaluate();
      expect(launcher.launched, isEmpty);
      expect(timers.pending.map((t) => t.delay), [backlog.workflow.claimLease]);

      clock.advance(backlog.workflow.claimLease);
      timers.fireAll();
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0002@w1']);
    });

    test('a failed launch is reported and tried again on the next evaluation', () async {
      final dispatcher = await start('auto', worktrees: ['w1']);
      await todo('A');
      launcher.failNext = true;
      await dispatcher.evaluate();
      expect(errors, hasLength(1));
      expect(launcher.launched, isEmpty);
      await dispatcher.evaluate();
      expect(launcher.launched, ['T-0001@w1']);
    });

    test('unavailable worktrees and held items are skipped; unavailable ones are checked again soon', () async {
      final dispatcher = await start('auto');
      await todo('A', priority: 'p0');
      await todo('B');
      launcher.given = DispatchConditions(
        unavailable: {'w1': 'uncommitted changes (2 paths)'},
        held: {ItemId('T-0001'): 'stopped'},
      );
      final plan = (await dispatcher.evaluate())!;
      expect(launcher.launched, ['T-0002@w2']);
      expect(plan.worktrees.first.isFree, isFalse);
      expect(plan.held.single.item.id, ItemId('T-0001'));
      expect(timers.pending.map((t) => t.delay), contains(dispatcher.unavailableRecheck));
    });

    test('a running agent occupies its worktree even without a claim', () async {
      final dispatcher = await start('manual', worktrees: ['w1']);
      await todo('A');
      launcher.given = DispatchConditions(
        runs: [AgentRun(item: ItemId('T-0009'), worktree: 'w1', pid: 1, startedAt: clock.now(), log: '/l', agent: 'x')],
      );
      final plan = (await dispatcher.evaluate())!;
      expect(plan.running, 1);
      expect(plan.assignments, isEmpty);
      await expectLater(dispatcher.start('T-0001'), throwsA(isA<UnavailableException>()));
    });

    test('a broken snapshot is reported and keeps the previous plan', () async {
      var fail = false;
      (backlog, clock) = await tempBacklog(config: 'dispatcher: {worktrees: [w1], command: agent}\n');
      final errors = <Object>[];
      final dispatcher = Dispatcher(
        snapshot: () => fail ? Future.error(const ConfigurationException('broken')) : backlog.planning.snapshot(),
        backlogRoot: backlog.root,
        launcher: _RecordingLauncher(backlog),
        clock: clock,
        timer: _FakeTimers().create,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(dispatcher.close);
      final first = await dispatcher.evaluate();
      fail = true;
      expect(await dispatcher.evaluate(), same(first));
      expect(errors.single, isA<ConfigurationException>());
    });
  });
}

/// Records launches; claims the item like a real launcher would, unless told not to.
final class _RecordingLauncher extends AgentLauncher {
  _RecordingLauncher(this.backlog);

  final Backlog backlog;
  final launched = <String>[];
  bool claims = true;
  bool failNext = false;
  DispatchConditions given = DispatchConditions.none;

  @override
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async =>
      given;

  @override
  Future<void> launch(DispatchAssignment assignment) async {
    if (failNext) {
      failNext = false;
      throw StateError('cannot start');
    }
    if (claims) await backlog.claims.claim('${assignment.id}', assignment.agent);
    launched.add(assignment.key);
  }
}

final class _FakeTimers {
  final _all = <_FakeTimer>[];

  Iterable<_FakeTimer> get pending => _all.where((t) => t.isActive);

  Timer create(Duration delay, void Function() callback) {
    final timer = _FakeTimer(delay, callback);
    _all.add(timer);
    return timer;
  }

  void fireAll() {
    for (final timer in pending.toList()) {
      timer.fire();
    }
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
