import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

const _config = '''
# Backlog configuration.
id:
  prefix: HB   # ids like HB-7f3a
  length: 4

statuses:
  - id: todo
    category: open
    pickable: true
  - id: doing   # the work
    category: active
  - id: review
    category: active
  - id: done
    category: done

priorities: [high, normal, low]

milestones:
  - v1
  - id: v2
    title: Second

defaults:
  status: todo
  priority: normal

appearance:
  statuses: {doing: "#fb8c00"}

dispatcher:
  worktrees: [w1]
  actions:
    - name: AI review
      review: true
      on_enter: review
      statuses: [doing, review]
custom_key: kept
''';

Workflow _parse(WorkflowSettings settings) => parseWorkflowYaml(settings.draft.text);

void main() {
  late WorkflowSettings settings;

  setUp(() => settings = WorkflowSettings(ConfigDraft(_config)));

  test('reads the lists, defaults, ids and claims leniently', () {
    expect(settings.ids(WorkflowList.statuses), ['todo', 'doing', 'review', 'done']);
    expect(settings.entries(WorkflowList.statuses).first.pickable, isTrue);
    expect(settings.entries(WorkflowList.statuses)[1].category, 'active');
    expect(settings.ids(WorkflowList.priorities), ['high', 'normal', 'low']);
    expect(settings.isBuiltIn(WorkflowList.types), isTrue);
    expect(settings.ids(WorkflowList.types), Workflow.standard().types);
    expect(settings.entries(WorkflowList.milestones).map((m) => (m.id, m.title)), [('v1', null), ('v2', 'Second')]);
    expect(settings.effectiveDefault(WorkflowList.priorities), 'normal');
    expect(settings.writtenDefault(WorkflowList.types), isNull);
    expect(settings.effectiveDefault(WorkflowList.types), 'task');
    expect(settings.idPrefix, 'HB');
    expect(settings.idLength, 4);
    expect(settings.leaseMinutes, 240);
  });

  test('renaming a status follows its references and keeps the rest', () {
    settings.rename(WorkflowList.statuses, 1, 'in-progress');
    final text = settings.draft.text;
    expect(text, contains('  - id: in-progress   # the work'));
    expect(text, contains('statuses: [in-progress, review]'));
    expect(settings.draft.valueAt(['appearance', 'statuses']), {'in-progress': '#fb8c00'});
    expect(text, contains('custom_key: kept'));
    expect(_parse(settings).statuses.map((s) => s.id), ['todo', 'in-progress', 'review', 'done']);

    settings.rename(WorkflowList.statuses, 0, 'ready');
    expect(settings.writtenDefault(WorkflowList.statuses), 'ready');
    settings.rename(WorkflowList.statuses, 2, 'check');
    expect(settings.draft.valueAt(['dispatcher', 'actions', 0, 'on_enter']), 'check');
    expect(_parse(settings).defaultStatus, 'ready');
  });

  test('renames priorities and milestones, refuses duplicates and spaces', () {
    settings.rename(WorkflowList.priorities, 1, 'medium');
    expect(settings.draft.text, contains('priorities: [high, medium, low]'));
    expect(settings.writtenDefault(WorkflowList.priorities), 'medium');
    settings.rename(WorkflowList.milestones, 0, 'v1.0');
    settings.rename(WorkflowList.milestones, 1, 'v2.0');
    expect(settings.ids(WorkflowList.milestones), ['v1.0', 'v2.0']);
    expect(settings.entries(WorkflowList.milestones)[1].title, 'Second');
    expect(() => settings.rename(WorkflowList.priorities, 0, 'low'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.rename(WorkflowList.priorities, 0, 'very high'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.rename(WorkflowList.priorities, 5, 'x'), throwsA(isA<InvalidInputException>()));
  });

  test('adds a status after the last one of its category, moves and removes entries', () {
    settings.add(WorkflowList.statuses, 'backlog', category: StatusCategory.open, at: 0);
    settings.add(WorkflowList.statuses, 'deploy', category: StatusCategory.active);
    settings.add(WorkflowList.statuses, 'cancelled', category: StatusCategory.done);
    expect(settings.ids(WorkflowList.statuses), ['backlog', 'todo', 'doing', 'review', 'deploy', 'done', 'cancelled']);
    expect(settings.entries(WorkflowList.statuses)[4].category, 'active');

    settings.move(WorkflowList.statuses, 4, 2);
    expect(settings.ids(WorkflowList.statuses), ['backlog', 'todo', 'deploy', 'doing', 'review', 'done', 'cancelled']);
    expect(() => settings.move(WorkflowList.statuses, 6, 7), throwsA(isA<InvalidInputException>()));

    settings.remove(WorkflowList.statuses, 2);
    settings.add(WorkflowList.priorities, 'urgent', at: 0);
    settings.move(WorkflowList.priorities, 3, 2);
    expect(settings.ids(WorkflowList.priorities), ['urgent', 'high', 'low', 'normal']);
    expect(_parse(settings).statuses.map((s) => s.id), ['backlog', 'todo', 'doing', 'review', 'done', 'cancelled']);
    expect(settings.draft.text, contains('# Backlog configuration.'));
  });

  test('the first edit of a built-in list writes it out', () {
    settings.add(WorkflowList.types, 'chore');
    expect(settings.isBuiltIn(WorkflowList.types), isFalse);
    expect(_parse(settings).types, [...Workflow.standard().types, 'chore']);

    final empty = WorkflowSettings(ConfigDraft(''));
    empty.setPickable(0, true);
    expect(_parse(empty).statuses.map((s) => (s.id, s.pickable)).take(2), [('backlog', true), ('todo', true)]);
    empty.add(WorkflowList.milestones, 'v0.1');
    expect(_parse(empty).milestones.single.id, 'v0.1');
  });

  test('sets the category, pickable and milestone titles', () {
    settings.setCategory(2, StatusCategory.done);
    settings.setPickable(0, false);
    expect(settings.draft.valueAt(['statuses', 0]), {'id': 'todo', 'category': 'open'});
    settings.setPickable(0, true);
    settings.setPickable(2, true);
    expect(settings.entries(WorkflowList.statuses)[2].category, 'done');
    expect(settings.entries(WorkflowList.statuses)[2].pickable, isTrue);

    settings.setMilestone(0, title: 'First', due: '2026-12-01');
    expect(settings.draft.valueAt(['milestones', 0]), {'id': 'v1', 'title': 'First', 'due': '2026-12-01'});
    settings.setMilestone(1, title: '');
    expect(settings.draft.valueAt(['milestones', 1]), {'id': 'v2'});
    expect(_parse(settings).milestones.first.due, '2026-12-01');
  });

  test('defaults, ids and claims are checked on input', () {
    settings.setDefault(WorkflowList.types, 'bug');
    expect(settings.effectiveDefault(WorkflowList.types), 'bug');
    settings.setDefault(WorkflowList.priorities, null);
    expect(settings.effectiveDefault(WorkflowList.priorities), 'normal'); // the middle one
    expect(() => settings.setDefault(WorkflowList.statuses, 'nope'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setDefault(WorkflowList.milestones, 'v1'), throwsA(isA<InvalidInputException>()));

    settings
      ..setIdPrefix('KA')
      ..setIdLength(6)
      ..setLeaseMinutes(60);
    expect(settings.draft.text, contains('prefix: KA   # ids like HB-7f3a'));
    final workflow = _parse(settings);
    expect((workflow.idPrefix, workflow.idLength, workflow.claimLease), ('KA', 6, const Duration(hours: 1)));
    expect(() => settings.setIdPrefix('1x'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setIdLength(2), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setLeaseMinutes(0), throwsA(isA<InvalidInputException>()));
  });

  test('ConfigDraft.insert puts values into a list', () {
    final draft = ConfigDraft('a: [x, z]\n')..insert(['a'], 1, 'y');
    expect(draft.valueAt(['a']), ['x', 'y', 'z']);
    draft.insert(['a'], 3, 'end');
    expect(draft.valueAt(['a']), ['x', 'y', 'z', 'end']);
    expect(() => draft.insert(['a'], 9, 'no'), throwsA(isA<InvalidInputException>()));
    expect(() => draft.insert(['b'], 0, 'no'), throwsA(isA<InvalidInputException>()));
  });
}
