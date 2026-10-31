import 'dart:math';

import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_core/src/workflow/infrastructure/yaml_workflow.dart' show workflowTemplate;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Workflow', () {
    test('standard workflow derives statuses by category', () {
      final workflow = Workflow.standard();
      expect(workflow.activeStatus, 'in-progress');
      expect(workflow.doneStatus, 'done');
      expect(workflow.pickableStatus, 'todo');
      expect(workflow.priorityRank('p0'), lessThan(workflow.priorityRank('p3')));
      expect(workflow.priorityRank('nonsense'), workflow.priorities.length);
    });

    test('rejects a workflow without a done status', () {
      expect(
        () => Workflow(
          statuses: const [
            StatusDefinition('todo', StatusCategory.open, pickable: true),
            StatusDefinition('doing', StatusCategory.active),
          ],
          priorities: const ['p1'],
          types: const ['task'],
        ),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('parses backlog.yaml and keeps standard values for missing sections', () {
      final workflow = parseWorkflowYaml('''
id: {prefix: HB, length: 5}
priorities: [urgent, normal, low]
milestones:
  - id: launch
    title: Launch
claims: {lease_minutes: 30}
''');
      expect(workflow.idPrefix, 'HB');
      expect(workflow.idLength, 5);
      expect(workflow.priorities, ['urgent', 'normal', 'low']);
      expect(workflow.defaultPriority, 'normal');
      expect(workflow.statuses.map((s) => s.id), contains('in-progress'));
      expect(workflow.acceptsMilestone('launch'), isTrue);
      expect(workflow.acceptsMilestone('other'), isFalse);
      expect(workflow.claimLease, const Duration(minutes: 30));
    });

    test('reads appearance colours in any accepted spelling', () {
      final appearance = parseWorkflowYaml('''
appearance:
  mode: dark
  light: {seed: "#3F51B5", background: fafafa}
  dark: {seed: "#abc"}
  statuses: {todo: "#1e88e5"}
  priorities: {p0: "e53935"}
  labels: {infra: "#00897b"}
''').appearance;
      expect(appearance.mode, 'dark');
      expect(appearance.light.seed, '#3f51b5');
      expect(appearance.light.background, '#fafafa');
      expect(appearance.dark.seed, '#aabbcc');
      expect(appearance.dark.primary, isNull);
      expect(appearance.statuses, {'todo': '#1e88e5'});
      expect(appearance.priorities, {'p0': '#e53935'});
      expect(appearance.labels, {'infra': '#00897b'});
      expect(Workflow.standard().appearance.mode, 'system');
    });

    test('rejects bad colours and modes', () {
      expect(
        () => parseWorkflowYaml('appearance: {statuses: {todo: "blue"}}'),
        throwsA(
          isA<ConfigurationException>().having((e) => e.message, 'message', contains('appearance.statuses.todo')),
        ),
      );
      expect(() => parseWorkflowYaml('appearance: {mode: dim}'), throwsA(isA<ConfigurationException>()));
    });

    test('the init template parses, including its commented appearance', () {
      final template = workflowTemplate(idPrefix: 'X');
      expect(parseWorkflowYaml(template).appearance.mode, 'system');
      final start = template.indexOf('# appearance:');
      final uncommented =
          template.substring(0, start) + template.substring(start).replaceAll(RegExp(r'^# ', multiLine: true), '');
      expect(parseWorkflowYaml(uncommented).appearance.priorities['p0'], '#e53935');
    });

    test('free-form milestones when none are listed', () {
      expect(Workflow.standard().acceptsMilestone('anything'), isTrue);
    });
  });

  group('ItemReference', () {
    final known = ['T-7f3a', 'T-7f9b', 'T-a2c4'].map(ItemId.new).toList();

    test('resolves exact, case-insensitive, suffix and prefix references', () {
      expect(ItemReference.resolve('T-7f3a', known), ItemId('T-7f3a'));
      expect(ItemReference.resolve('t-7F3A', known), ItemId('T-7f3a'));
      expect(ItemReference.resolve('a2c4', known), ItemId('T-a2c4'));
      expect(ItemReference.resolve('a2', known), ItemId('T-a2c4'));
      expect(ItemReference.resolve('T-7f3', known), ItemId('T-7f3a'));
    });

    test('reports ambiguity and absence', () {
      expect(
        () => ItemReference.resolve('7f', known),
        throwsA(isA<AmbiguousReferenceException>().having((e) => e.candidates, 'candidates', hasLength(2))),
      );
      expect(() => ItemReference.resolve('zzz', known), throwsA(isA<NotFoundException>()));
    });
  });

  test('RandomIdGenerator uses the prefix and the readable alphabet', () {
    final ids = RandomIdGenerator(prefix: 'HB', length: 6, random: Random(1));
    for (var i = 0; i < 100; i++) {
      expect(ids.next().value, matches(RegExp(r'^HB-[23456789abcdefghjkmnpqrstuvwxyz]{6}$')));
    }
  });

  test('Checklist counts task-list lines outside code fences', () {
    final checklist = Checklist.parse('''
## Done
- [x] first
* [X] second
1. [ ] third
- [ ] fourth
```
- [ ] not a task
```
- plain item
''');
    expect(checklist.done, 2);
    expect(checklist.total, 4);
  });

  test('FieldChange parses set, add, remove and clear', () {
    expect(FieldChange.parse('status=done').op, ChangeOp.set);
    expect(FieldChange.parse('labels+=a, b').values, ['a', 'b']);
    expect(FieldChange.parse('depends_on-=T-1').op, ChangeOp.remove);
    expect(FieldChange.parse('milestone=').clears, isTrue);
    expect(FieldChange.parse('title=Fix: a = b').value, 'Fix: a = b');
    expect(() => FieldChange.parse('nonsense'), throwsA(isA<InvalidInputException>()));
    expect(FieldChange.parse('touches+=lib/*.{dart,yaml}, docs/').values, ['lib/*.{dart,yaml}', 'docs/']);
  });

  group('BacklogSnapshot', () {
    test('an item is blocked until its dependencies are done', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'in-progress'),
        item('T-2', dependsOn: ['T-1']),
        item('T-3', dependsOn: ['T-4']),
        item('T-4', status: 'done'),
      ]);
      expect(snapshot[ItemId('T-2')]!.isBlocked, isTrue);
      expect(snapshot[ItemId('T-2')]!.openDependencies, [ItemId('T-1')]);
      expect(snapshot[ItemId('T-3')]!.isBlocked, isFalse);
      expect(snapshot.ready.map((i) => i.id.value), ['T-3']);
      expect(snapshot.dependentsOf(ItemId('T-1')).map((i) => i.id.value), ['T-2']);
    });

    test('a missing dependency blocks too', () {
      final planned = snapshotOf([
        item('T-1', dependsOn: ['T-404']),
      ])[ItemId('T-1')]!;
      expect(planned.isBlocked, isTrue);
      expect(planned.missingDependencies, [ItemId('T-404')]);
    });

    test('only pickable statuses are ready, and parents wait for children', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'backlog'),
        item('E-1', type: 'epic'),
        item('T-2', parent: 'E-1'),
        item('T-3', parent: 'E-1', status: 'done'),
      ]);
      expect(snapshot.ready.map((i) => i.id.value), ['T-2']);
      expect(snapshot[ItemId('E-1')]!.childCount, 2);
      expect(snapshot[ItemId('E-1')]!.openChildCount, 1);
    });

    test('a live claim hides an item from ready, an expired one does not', () {
      final now = DateTime.utc(2026, 10, 29, 12);
      Claim claimAt(String id, DateTime at) =>
          Claim(itemId: ItemId(id), agent: 'a', claimedAt: at, heartbeatAt: at, lease: const Duration(hours: 1));
      final snapshot = snapshotOf(
        [item('T-1'), item('T-2')],
        claims: [claimAt('T-1', now), claimAt('T-2', now.subtract(const Duration(hours: 2)))],
        now: now,
      );
      expect(snapshot[ItemId('T-1')]!.isClaimed, isTrue);
      expect(snapshot[ItemId('T-2')]!.isClaimExpired, isTrue);
      expect(snapshot.ready.map((i) => i.id.value), ['T-2']);
    });

    test('an open item whose touches overlap active work waits for it', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'in-progress', touches: ['lib/payments/']),
        item('T-2', status: 'review', touches: ['docs/*.md']),
        item('T-3', touches: ['lib/payments/stripe.dart']),
        item('T-4', touches: ['lib/orders/', 'docs/payments.md']),
        item('T-5', touches: ['lib/orders/']),
        item('T-6'), // no touches: never conflicts
        item('T-7', status: 'backlog', touches: ['lib/**']),
        item('T-8', status: 'done', touches: ['lib/payments/']),
        item('T-9', status: 'in-progress', touches: ['lib/payments/']), // active ones do not wait
      ]);
      List<String> conflicts(String id) => [for (final c in snapshot[ItemId(id)]!.conflictsWith) c.value];
      expect(conflicts('T-3'), ['T-1', 'T-9']);
      expect(conflicts('T-4'), ['T-2']);
      expect(conflicts('T-5'), isEmpty);
      expect(conflicts('T-6'), isEmpty);
      expect(conflicts('T-7'), ['T-1', 'T-9']); // open but not pickable: waits, still not ready
      expect(conflicts('T-8'), isEmpty);
      expect(conflicts('T-9'), isEmpty);
      expect(snapshot[ItemId('T-3')]!.isConflicting, isTrue);
      expect(snapshot[ItemId('T-3')]!.isBlocked, isFalse);
      expect(snapshot.ready.map((i) => i.id.value), unorderedEquals(['T-5', 'T-6']));
      expect(snapshot.conflicting.map((i) => i.id.value), unorderedEquals(['T-3', 'T-4', 'T-7']));
      expect(snapshot.waitingOn(ItemId('T-1')).map((i) => i.id.value), unorderedEquals(['T-3', 'T-7']));
      final view = parseFilter({'conflicting': true, 'conflicts_with': 'T-2'});
      expect(snapshot.items.where(view.matches).map((i) => i.id.value), ['T-4']);
    });

    test('orders by priority, then creation date', () {
      final snapshot = snapshotOf([
        item('T-1', priority: 'p2', created: '2026-01-01'),
        item('T-2', priority: 'p0', created: '2026-05-01'),
        item('T-3', priority: 'p2', created: '2025-12-01'),
      ]);
      expect(snapshot.items.map((i) => i.id.value), ['T-2', 'T-3', 'T-1']);
    });

    test('finds dependency and parent cycles', () {
      final snapshot = snapshotOf([
        item('T-1', dependsOn: ['T-2']),
        item('T-2', dependsOn: ['T-3']),
        item('T-3', dependsOn: ['T-1']),
        item('T-4', dependsOn: ['T-1']),
        item('T-5', parent: 'T-6'),
        item('T-6', parent: 'T-5'),
      ]);
      expect(snapshot.dependencyCycles(), hasLength(1));
      expect(snapshot.dependencyCycles().single.toSet(), {ItemId('T-1'), ItemId('T-2'), ItemId('T-3')});
      expect(snapshot.parentCycles(), hasLength(1));
    });
  });

  group('views', () {
    final snapshot = snapshotOf([
      item('T-1', status: 'todo', priority: 'p1', labels: ['infra', 'db'], milestone: 'launch'),
      item('T-2', status: 'in-progress', priority: 'p0', labels: ['ui']),
      item('T-3', status: 'done', priority: 'p0', milestone: 'launch'),
      item('T-4', status: 'backlog', priority: 'p3', dependsOn: ['T-2']),
    ]);

    List<String> ids(ViewResult result) => result.items.map((i) => i.id.value).toList();

    test('filter expressions: AND of entries, or, not, exists, computed fields', () {
      ViewResult run(String filter) => ViewEngine.evaluate(
        parseViewYaml('v', 'filter:\n${filter.split('\n').map((l) => '  $l').join('\n')}'),
        snapshot,
      );
      expect(ids(run('milestone: launch\nstatus: {not: [done]}')), ['T-1']);
      expect(ids(run('labels: db')), ['T-1']);
      expect(ids(run('or:\n  - labels: ui\n  - priority: p3')), ['T-2', 'T-4']);
      expect(ids(run('milestone: {exists: false}')), ['T-2', 'T-4']);
      expect(ids(run('blocked: true')), ['T-4']);
      expect(ids(run('ready: true')), ['T-1']);
      expect(ids(run('not: {category: [done, active]}')), ['T-1', 'T-4']);
    });

    test('kanban groups by workflow statuses and counts hidden items', () {
      final result = ViewEngine.evaluate(
        parseViewYaml('board', 'layout: kanban\ngroup_by: status\ncolumns: [todo, in-progress]'),
        snapshot,
      );
      expect(result.definition.layout, ViewLayout.kanban);
      expect(result.groups.map((g) => g.key), ['todo', 'in-progress']);
      expect(result.groups.map((g) => g.items.length), [1, 1]);
      expect(result.hidden, 2);
    });

    test('grouping without columns follows the workflow and adds an empty-value group', () {
      final byStatus = ViewEngine.evaluate(parseViewYaml('s', 'group_by: status'), snapshot);
      expect(byStatus.groups.map((g) => g.key), Workflow.standard().statuses.map((s) => s.id));
      final byMilestone = ViewEngine.evaluate(parseViewYaml('m', 'group_by: milestone'), snapshot);
      expect(byMilestone.groups.map((g) => g.key), ['launch', '']);
    });

    test('sorts by keys, descending with a dash', () {
      final result = ViewEngine.evaluate(parseViewYaml('s', 'sort: [-priority, id]'), snapshot);
      expect(ids(result), ['T-4', 'T-1', 'T-2', 'T-3']);
    });

    test('rejects unknown layouts and operators', () {
      expect(() => parseViewYaml('v', 'layout: pie'), throwsA(isA<ConfigurationException>()));
      expect(() => parseViewYaml('v', 'filter: {status: {like: x}}'), throwsA(isA<ConfigurationException>()));
    });
  });
}
