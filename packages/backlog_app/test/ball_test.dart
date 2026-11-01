import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/dispatch/application/ball.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

final _started = DateTime.utc(2026, 11, 1, 12);

AgentRunDto _run(String item, {String? action, String worktree = 'w1'}) => AgentRunDto(
  item: item,
  worktree: worktree,
  pid: 1,
  startedAt: _started,
  log: '/l/$item.log',
  agent: action == null ? 'claude' : 'reviewer',
  action: action,
);

const _workflow = WorkflowDto(
  statuses: [],
  priorities: ['p2'],
  types: ['task'],
  defaultStatus: 'todo',
  defaultPriority: 'p2',
  defaultType: 'task',
  actions: [
    ActionDto(name: 'AI review', kind: 'prompt', review: true),
    ActionDto(name: 'Fix', kind: 'prompt'),
  ],
);

DispatchDto _plan({
  List<AgentRunDto> runs = const [],
  List<ProblemItemDto> problems = const [],
  List<HeldItemDto> held = const [],
  List<QueuedStartDto> queue = const [],
  List<PendingActionDto> pending = const [],
}) => DispatchDto(
  configured: true,
  mode: 'manual',
  runs: runs,
  problems: problems,
  held: held,
  queue: queue,
  pendingActions: pending,
);

BallHolder? _holder(ItemDto item, DispatchDto plan) => Ball.of(item, plan, _workflow)?.holder;

void main() {
  test('nobody has the ball without a dispatcher, of finished items and of untouched work', () {
    expect(Ball.of(item('A-1', status: 'review'), DispatchDto.off, _workflow), isNull);
    expect(_holder(item('A-1', status: 'done'), _plan(runs: [_run('A-1')])), isNull);
    expect(_holder(item('A-1', ready: true), _plan()), isNull);
  });

  test('a running agent or code-changing action has it, an AI review action is AI review', () {
    expect(_holder(item('A-1', status: 'in-progress'), _plan(runs: [_run('A-1')])), BallHolder.agent);
    expect(_holder(item('A-1', status: 'review'), _plan(runs: [_run('A-1', action: 'Fix')])), BallHolder.agent);
    final review = Ball.of(item('A-1', status: 'review'), _plan(runs: [_run('A-1', action: 'AI review')]), _workflow);
    expect(review?.holder, BallHolder.aiReview);
    expect(review?.reason, 'AI review "AI review" runs in w1');
    // A running agent wins over the item's status and an old question.
    expect(_holder(item('A-1', status: 'review', needsHuman: true), _plan(runs: [_run('A-1')])), BallHolder.agent);
  });

  test('the agent of an epic has the ball of the children its worktree claims', () {
    final ball = Ball.of(item('T-1', claimedBy: 'w1'), _plan(runs: [_run('E-1')]), _workflow);
    expect(ball?.holder, BallHolder.agent);
    expect(ball?.reason, contains('The agent of E-1'));
  });

  test('a question, problems, a hold or the review status wait for you', () {
    expect(_holder(item('A-1', needsHuman: true), _plan()), BallHolder.you);
    final problems = Ball.of(
      item('A-1'),
      _plan(
        problems: const [
          ProblemItemDto(item: 'A-1', title: 'A', problems: ['the agent exited with code 1']),
        ],
      ),
      _workflow,
    );
    expect(problems?.holder, BallHolder.you);
    expect(problems?.problems, isTrue);
    expect(
      _holder(
        item('A-1'),
        _plan(
          held: const [HeldItemDto(item: 'A-1', title: 'A', reason: 'stopped')],
        ),
      ),
      BallHolder.you,
    );
    final review = Ball.of(item('A-1', status: 'review'), _plan(), _workflow);
    expect(review?.holder, BallHolder.you);
    expect(review?.reason, 'Waits for your review');
  });

  test('a queued start or a pending on_enter action is in the queue, before the review status', () {
    final queued = Ball.of(
      item('A-1', ready: true),
      _plan(
        queue: [
          QueuedStartDto(
            item: 'A-1',
            title: 'A',
            kind: 'agent',
            since: _started,
            reason: 'a free worktree',
            position: 2,
          ),
        ],
      ),
      _workflow,
    );
    expect(queued?.holder, BallHolder.queue);
    expect(queued?.reason, 'Queued: Start agent waits for a free worktree · position 2');
    final pending = Ball.of(
      item('A-1', status: 'review'),
      _plan(
        pending: [PendingActionDto(item: 'A-1', action: 'AI review', status: 'review', since: _started)],
      ),
      _workflow,
    );
    expect(pending?.holder, BallHolder.queue);
    expect(pending?.reason, contains('"AI review"'));
  });
}
