import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  EpicPlan planOf(List<Item> items, {String epic = 'E-1', List<Claim> claims = const [], String? agent}) =>
      EpicPlan.of(snapshotOf(items, claims: claims), ItemId(epic), agent: agent);

  Claim claim(String id, String agent) {
    final at = DateTime.utc(2026, 10, 29, 11);
    return Claim(itemId: ItemId(id), agent: agent, claimedAt: at, heartbeatAt: at, lease: const Duration(hours: 4));
  }

  group('EpicPlan', () {
    test('orders the items by dependencies and children, then by urgency', () {
      final plan = planOf([
        item('E-1', type: 'epic'),
        item('S-1', type: 'story', parent: 'E-1', priority: 'p0'),
        item('T-1', parent: 'S-1', dependsOn: ['T-2']),
        item('T-2', parent: 'S-1', priority: 'p3'),
        item('T-3', parent: 'E-1', priority: 'p1'),
      ]);
      // Like `backlog next`: the most urgent item that can be done first.
      expect(plan.members.map((m) => m.id.value), ['T-3', 'T-2', 'T-1', 'S-1']);
      expect(plan.verdict, EpicVerdict.ok);
      expect(plan.branch, 'agent/E-1');
      expect(plan.next!.id.value, 'T-3');
      expect(plan.members[2].after, [ItemId('T-2')]);
      expect(plan.members[3].after, [ItemId('T-1'), ItemId('T-2')]);
    });

    test('handed-over items count as done for the items after them', () {
      final plan = planOf([
        item('E-1', type: 'epic'),
        item('T-1', parent: 'E-1', status: 'review'),
        item('T-2', parent: 'E-1', dependsOn: ['T-1']),
        item('T-3', parent: 'E-1', status: 'done'),
      ]);
      expect(plan.members.map((m) => m.state), [
        EpicMemberState.handedOver,
        EpicMemberState.remaining,
        EpicMemberState.done,
      ]);
      expect(plan.next!.id.value, 'T-2');
      expect(plan.finished, isFalse);
      expect(plan.count(EpicMemberState.handedOver), 1);
    });

    test('the agent goes on with the item it has in progress', () {
      final plan = planOf(
        [
          item('E-1', type: 'epic', status: 'in-progress'),
          item('T-1', parent: 'E-1', status: 'in-progress'),
          item('T-2', parent: 'E-1'),
        ],
        claims: [claim('E-1', 'w1'), claim('T-1', 'w1')],
        agent: 'w1',
      );
      expect(plan.verdict, EpicVerdict.ok);
      expect(plan.next!.id.value, 'T-1');
    });

    test('an item in progress of another agent is a warning and holds up the items after it', () {
      final plan = planOf(
        [
          item('E-1', type: 'epic'),
          item('T-1', parent: 'E-1', status: 'in-progress'),
          item('T-2', parent: 'E-1', dependsOn: ['T-1']),
        ],
        claims: [claim('T-1', 'w2')],
        agent: 'w1',
      );
      expect(plan.verdict, EpicVerdict.warning);
      expect(plan.warnings.single, contains('claimed by w2'));
      expect(plan.next, isNull);
    });

    test('a planned dependency outside the epic is a warning, an unplanned or missing one forbids', () {
      final planned = planOf([
        item('E-1', type: 'epic'),
        item('T-1', parent: 'E-1', dependsOn: ['X-1']),
        item('T-2', parent: 'E-1'),
        item('X-1'),
      ]);
      expect(planned.verdict, EpicVerdict.warning);
      expect(planned.members.first.waits, ['X-1 (todo)']);
      expect(planned.next!.id.value, 'T-2');

      final unplanned = planOf([
        item('E-1', type: 'epic', dependsOn: ['X-1']),
        item('T-1', parent: 'E-1'),
        item('X-1', status: 'backlog'),
      ]);
      expect(unplanned.verdict, EpicVerdict.forbidden);
      expect(unplanned.problems.single, 'E-1 depends on X-1 (backlog), which is not done and not even planned.');
      expect(unplanned.members.single.waits, ['X-1 (backlog)']);

      final missing = planOf([
        item('E-1', type: 'epic'),
        item('T-1', parent: 'E-1', dependsOn: ['X-404']),
      ]);
      expect(missing.problems.single, 'T-1 depends on X-404, which does not exist.');
    });

    test('questions and overlapping work outside the epic are warnings', () {
      final plan = planOf([
        item('E-1', type: 'epic'),
        item('T-1', parent: 'E-1', body: '## Discussion\n\n### w1 · 2026-10-29 10:00:00 UTC · question\n\nCSV?\n'),
        item('T-2', parent: 'E-1', touches: ['lib/a/']),
        item('T-3', parent: 'E-1', touches: ['lib/b/']),
        item('T-4', parent: 'E-1', status: 'in-progress', touches: ['lib/b/']),
        item('X-1', status: 'in-progress', touches: ['lib/a/']),
      ]);
      expect(plan.verdict, EpicVerdict.warning);
      final waits = {for (final m in plan.members) m.id.value: m.waits};
      expect(waits['T-1'], ["a person's answer to its question"]);
      expect(waits['T-2'], ['X-1 (touches the same files)']);
      expect(waits['T-3'], isEmpty); // overlapping work of the epic itself is fine
      expect(plan.warnings, hasLength(2));
    });

    test('cycles, a done epic, a claimed epic and nothing left forbid the start', () {
      final cycle = planOf([
        item('E-1', type: 'epic'),
        item('T-1', parent: 'E-1', dependsOn: ['T-2']),
        item('T-2', parent: 'E-1', dependsOn: ['T-1']),
      ]);
      expect(cycle.verdict, EpicVerdict.forbidden);
      expect(cycle.problems.single, contains('form a cycle'));
      expect(cycle.members, hasLength(2));

      expect(planOf([item('E-1', type: 'epic')]).problems, ['E-1 has no child items to implement.']);
      expect(planOf([item('E-1', type: 'epic'), item('T-1', parent: 'E-1', status: 'review')]).problems, [
        'Nothing left to implement: every item of E-1 is handed over or done.',
      ]);
      expect(planOf([item('E-1', type: 'epic', status: 'done'), item('T-1', parent: 'E-1')]).problems, [
        'E-1 is already done.',
      ]);
      final items = [item('E-1', type: 'epic', status: 'in-progress'), item('T-1', parent: 'E-1')];
      expect(planOf(items, claims: [claim('E-1', 'w2')], agent: 'w1').problems, ['E-1 is claimed by w2.']);
      expect(planOf(items, claims: [claim('E-1', 'w1')], agent: 'w1').problems, isEmpty);
    });

    test('uses the branch of the epic', () {
      final epic = item('E-1', type: 'epic');
      final plan = planOf([epic.copyWith(branch: () => 'feat/epic'), item('T-1', parent: 'E-1')]);
      expect(plan.branch, 'feat/epic');
    });
  });

  group('ClaimService.claimInEpic', () {
    test('claims the items one after another on the epic branch', () async {
      final (backlog, _) = await tempBacklog();
      final epic = await backlog.items.create(const NewItem(title: 'Epic', type: 'epic', status: 'todo'));
      final first = await backlog.items.create(NewItem(title: 'First', parent: epic.id.value, status: 'todo'));
      await backlog.items.create(
        NewItem(title: 'Second', parent: epic.id.value, status: 'backlog', dependsOn: [first.id.value]),
      );

      var next = await backlog.claims.claimInEpic(epic.id.value, 'w1');
      expect(next.outcome!.item.id, first.id);
      expect(next.outcome!.item.branch, 'agent/${epic.id}');
      expect(next.outcome!.item.status, 'in-progress');

      // Still in progress: the same item again.
      next = await backlog.claims.claimInEpic(epic.id.value, 'w1');
      expect(next.outcome!.item.id, first.id);

      await backlog.items.update(first.id.value, [FieldChange.parse('status=review')]);
      next = await backlog.claims.claimInEpic(epic.id.value, 'w1');
      expect(next.outcome!.item.title, 'Second');

      await backlog.items.update(next.outcome!.item.id.value, [FieldChange.parse('status=review')]);
      next = await backlog.claims.claimInEpic(epic.id.value, 'w1');
      expect(next.outcome, isNull);
      expect(next.plan.finished, isTrue);
    });
  });
}
