import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/dispatch/application/next_step.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _started = DateTime.utc(2026, 11, 1, 12);

const _workflow = WorkflowDto(
  statuses: [],
  priorities: ['p2'],
  types: ['task'],
  defaultStatus: 'todo',
  defaultPriority: 'p2',
  defaultType: 'task',
  actions: [
    ActionDto(name: 'AI review', kind: 'prompt', review: true, onEnter: 'ai-review', statuses: ['review']),
    ActionDto(name: 'Fix review', kind: 'prompt', statuses: ['review']),
    ActionDto(name: 'Merge', kind: 'builtin', statuses: ['review']),
  ],
);

DispatchDto _plan({
  String mode = 'manual',
  List<AgentRunDto> runs = const [],
  List<ProblemItemDto> problems = const [],
  List<HeldItemDto> held = const [],
}) => DispatchDto(configured: true, mode: mode, runs: runs, problems: problems, held: held);

NextStep? _step(ItemDto item, [DispatchDto? plan, CommentDto? question]) =>
    NextStep.of(item, plan ?? _plan(), _workflow, question: question);

void main() {
  test('no step without a dispatcher, for finished items and while something runs', () {
    expect(NextStep.of(item('A-1', status: 'review'), DispatchDto.off, _workflow), isNull);
    expect(_step(item('A-1', status: 'done')), isNull);
    final run = AgentRunDto(item: 'A-1', worktree: 'w1', pid: 1, startedAt: _started, log: '/l', agent: 'claude');
    expect(_step(item('A-1', status: 'review', needsHuman: true), _plan(runs: [run])), isNull);
  });

  test('review: look through the PR and merge, resolve findings, or review again', () {
    final ok = _step(item('A-1', status: 'review', review: 'ok', pr: 'https://github.com/o/r/pull/12'))!;
    expect(ok.kind, NextStepKind.review);
    expect(ok.text, 'AI review ✓ – look through PR #12 and run "Merge"');
    expect(ok.actions, ['Merge']);
    expect(ok.pr, 'https://github.com/o/r/pull/12');

    final changes = _step(item('A-1', status: 'review', review: 'changes', reviewFindings: 2))!;
    expect(changes.kind, NextStepKind.resolve);
    expect(changes.text, 'AI review has 2 findings – resolve them with "Fix review" or answer in the discussion');
    expect(changes.actions, ['Fix review']);

    final stale = _step(item('A-1', status: 'review', review: 'stale', branch: 'agent/A-1'))!;
    expect(
      stale.text,
      'AI review is outdated (the branch has newer commits) – run "AI review" again, then run "Merge"',
    );
    expect(stale.actions, ['AI review', 'Merge']);

    expect(
      _step(item('A-1', status: 'review', branch: 'agent/A-1'))!.text,
      'Look through the branch agent/A-1 and run "Merge"',
    );
  });

  test('answer quotes the first line of the question', () {
    final question = CommentDto(author: 'w1', at: _started, text: 'CSV or JSON?\nMore context.', question: true);
    final answer = _step(item('A-1', needsHuman: true), null, question)!;
    expect(answer.kind, NextStepKind.answer);
    expect(answer.text, 'Answer w1: CSV or JSON?');
    expect(_step(item('A-1', needsHuman: true))!.text, 'Answer the agent\'s question in the discussion');
  });

  test('problems say what failed and how to retry', () {
    final plan = _plan(
      problems: const [
        ProblemItemDto(
          item: 'A-1',
          title: 'A',
          problems: ['merge failed: the primary clone has uncommitted changes', 'push refused'],
        ),
      ],
    );
    final fix = _step(item('A-1', status: 'review'), plan)!;
    expect(fix.kind, NextStepKind.fix);
    expect(
      fix.text,
      'merge failed: the primary clone has uncommitted changes (and 1 more) – fix it, then run "Merge" again',
    );
    expect(fix.actions, ['Merge']);
    final agent = _step(
      item('A-1', ready: true),
      _plan(
        problems: const [
          ProblemItemDto(item: 'A-1', title: 'A', problems: ['push failed: gh is not logged in']),
        ],
      ),
    )!;
    expect(agent.text, 'push failed: gh is not logged in – fix it, then start the agent again');
    expect(agent.start, isTrue);
  });

  test('held items start again, ready ones start in manual mode, blocked ones wait', () {
    final held = _step(
      item('A-1', ready: true),
      _plan(
        held: const [HeldItemDto(item: 'A-1', title: 'A', reason: 'the agent was stopped')],
      ),
    )!;
    expect(held.kind, NextStepKind.held);
    expect(held.start, isTrue);

    final start = _step(item('A-1', ready: true))!;
    expect(start.text, 'Ready and nothing runs – Start agent');
    expect(start.start, isTrue);
    expect(_step(item('A-1', ready: true), _plan(mode: 'auto')), isNull, reason: 'the dispatcher starts it');
    expect(
      _step(item('E-1', ready: true, children: const Progress(0, 2)))!.text,
      'Ready and nothing runs – Implement epic',
    );
    expect(_step(item('A-1', ready: true, claimedBy: 'w1')), isNull);

    final blocked = _step(item('A-1', blockedBy: ['A-0']))!;
    expect(blocked.kind, NextStepKind.unblock);
    expect(blocked.text, 'Waits for A-0 (not done yet)');
    expect(blocked.open, ['A-0']);
  });
}
