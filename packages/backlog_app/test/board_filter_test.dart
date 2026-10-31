import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
import 'package:backlog_app/shared/pr_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  final ui = item('T-1', labels: ['ui', 'web'], priority: 'p0');
  final backend = item('T-2', labels: ['backend'], type: 'bug');
  final plain = item('T-3', priority: 'p3');
  final claimed = ItemDto(
    id: 'T-4',
    title: 'Fix login redirect',
    type: 'task',
    status: 'todo',
    priority: 'p1',
    branch: 'fix/login',
    assignee: 'alice',
    ready: true,
    claim: ClaimDto(
      item: 'T-4',
      agent: 'monorepo-2',
      claimedAt: DateTime.utc(2026),
      heartbeatAt: DateTime.utc(2026),
      expiresAt: DateTime.utc(2027),
    ),
  );
  final all = [ui, backend, plain, claimed];

  List<String> ids(BoardFilter filter) => all.where(filter.matches).map((i) => i.id).toList();

  test('an empty filter lets everything through', () {
    expect(BoardFilter.none.isEmpty, isTrue);
    expect(ids(BoardFilter.none), ['T-1', 'T-2', 'T-3', 'T-4']);
  });

  test('values of one facet are alternatives, facets combine', () {
    final labels = BoardFilter.none.toggle(FilterFacet.label, 'ui').toggle(FilterFacet.label, 'backend');
    expect(ids(labels), ['T-1', 'T-2']);
    expect(ids(labels.toggle(FilterFacet.type, 'bug')), ['T-2']);
    expect(ids(labels.toggle(FilterFacet.label, 'ui')), ['T-2'], reason: 'toggling again removes the value');
  });

  test('people are the assignee and the claim holder', () {
    expect(ids(BoardFilter.none.toggle(FilterFacet.person, 'alice')), ['T-4']);
    expect(ids(BoardFilter.none.toggle(FilterFacet.person, 'monorepo-2')), ['T-4']);
  });

  test('text searches id, title and branch, ignoring case', () {
    expect(ids(BoardFilter.none.withText('LOGIN')), ['T-4']);
    expect(ids(BoardFilter.none.withText('fix/')), ['T-4']);
    expect(ids(BoardFilter.none.withText('t-2')), ['T-2']);
    expect(BoardFilter.none.withText('  ').isEmpty, isTrue);
  });

  test('flags must all hold', () {
    expect(ids(BoardFilter.none.toggleFlag(ItemFlag.claimed)), ['T-4']);
    expect(ids(BoardFilter.none.toggleFlag(ItemFlag.claimed).toggleFlag(ItemFlag.blocked)), isEmpty);
  });

  test('the waiting flag keeps items whose touches overlap work in progress', () {
    final waiting = item('T-7', conflictsWith: ['T-4']);
    final filter = BoardFilter.none.toggleFlag(ItemFlag.conflicting);
    expect(filter.matches(waiting), isTrue);
    expect(filter.matches(item('T-8')), isFalse);
    expect(filter.toConditions(), [
      {'conflicting': true},
    ]);
  });

  test('apply keeps every group, even emptied ones', () {
    final result = ViewResultDto(
      id: 'board',
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      groups: [
        ViewGroupDto('todo', [ui, plain]),
        ViewGroupDto('done', [backend]),
      ],
    );
    final filtered = BoardFilter.none.toggle(FilterFacet.label, 'ui').apply(result);
    expect(filtered.groups.map((g) => g.key), ['todo', 'done']);
    expect(filtered.groups.first.items.single.id, 'T-1');
    expect(filtered.groups.last.items, isEmpty);
    expect(BoardFilter.none.apply(result), same(result));
  });

  test('options follow the workflow order and keep the selection', () async {
    final workflow = await FakeBacklogApi(const []).workflow();
    final options = BoardFilter.options(all, workflow, current: BoardFilter.none.toggle(FilterFacet.label, 'gone'));
    expect(options[FilterFacet.priority], ['p0', 'p1', 'p2', 'p3']);
    expect(options[FilterFacet.type], ['task', 'bug']);
    expect(options[FilterFacet.label], ['backend', 'gone', 'ui', 'web']);
    expect(options[FilterFacet.person], ['alice', 'monorepo-2']);
    expect(options[FilterFacet.milestone], isEmpty);
  });

  test('the epic facet keeps everything under the chosen epic', () {
    final epic = item('E-1', type: 'epic');
    final story = item('S-1', type: 'story', parent: 'E-1');
    final task = item('T-9', parent: 'S-1');
    final other = item('T-8');
    final index = {
      for (final i in [epic, story, task, other]) i.id: i,
    };
    final filter = BoardFilter.none.toggle(FilterFacet.epic, 'E-1');

    expect([epic, story, task, other].where((i) => filter.matches(i, index)).map((i) => i.id), ['E-1', 'S-1', 'T-9']);
    expect(BoardFilter.options([story, task, other], null, index: index)[FilterFacet.epic], ['E-1']);
    expect(FilterFacet.epic.describe('E-1', index), 'Item E-1');
  });

  test('a parent cycle does not hang the epic lookup', () {
    final a = item('A', parent: 'B');
    final b = item('B', parent: 'A', type: 'epic');
    expect(FilterFacet.epic.valuesOf(a, {'A': a, 'B': b}), ['B']);
  });

  test('PR links are labelled with their number', () {
    expect(PrLink.label('https://github.com/o/r/pull/42'), 'PR #42');
    expect(PrLink.label('https://gitlab.com/g/p/-/merge_requests/7'), 'PR #7');
    expect(PrLink.label('https://example.com/review'), 'PR');
  });

  test('a filter becomes view conditions the server understands', () {
    final filter = BoardFilter.none
        .withText(' login ')
        .toggle(FilterFacet.label, 'ui')
        .toggle(FilterFacet.epic, 'E-1')
        .toggle(FilterFacet.person, 'alice')
        .toggleFlag(ItemFlag.ready);
    expect(filter.toConditions(), [
      {
        'or': [
          {
            'id': {'contains': 'login'},
          },
          {
            'title': {'contains': 'login'},
          },
          {
            'branch': {'contains': 'login'},
          },
        ],
      },
      {
        'labels': ['ui'],
      },
      {
        'epic': ['E-1'],
      },
      {
        'or': [
          {
            'assignee': ['alice'],
          },
          {
            'claimed_by': ['alice'],
          },
        ],
      },
      {'ready': true},
    ]);
    expect(BoardFilter.none.toggle(FilterFacet.type, 'bug').toggle(FilterFacet.type, 'bug').toConditions(), isEmpty);
  });

  test('counts tell how many items carry each value', () {
    final counts = BoardFilter.counts([ui, backend, plain]);
    expect(counts[FilterFacet.label], {'ui': 1, 'web': 1, 'backend': 1});
    expect(counts[FilterFacet.priority], {'p0': 1, 'p2': 1, 'p3': 1});
    expect(counts[FilterFacet.type], {'task': 2, 'bug': 1});
  });

  test('counts include epics above an item', () {
    final epic = item('E', type: 'epic');
    final child = item('C', parent: 'E');
    final counts = BoardFilter.counts([epic, child], index: {'E': epic, 'C': child});
    expect(counts[FilterFacet.epic], {'E': 2});
  });
}
