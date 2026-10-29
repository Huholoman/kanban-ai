import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
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
}
