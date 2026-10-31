import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/board/application/new_item_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  WorkflowDto workflow(List<String> types, {String defaultType = 'task'}) => WorkflowDto(
    statuses: const [StatusDto(id: 'todo', category: StatusCategoryDto.open)],
    priorities: const ['p2'],
    types: types,
    defaultStatus: 'todo',
    defaultPriority: 'p2',
    defaultType: defaultType,
  );

  test('a child is one level down: epic → story → task → subtask', () {
    final all = workflow(['epic', 'story', 'task', 'subtask', 'bug']);
    expect(NewItemDefaults.childType('epic', all), 'story');
    expect(NewItemDefaults.childType('story', all), 'task');
    expect(NewItemDefaults.childType('task', all), 'subtask');
    expect(NewItemDefaults.childType('subtask', all), 'subtask');
    expect(NewItemDefaults.childType('bug', all), 'task', reason: 'outside the levels: the default type');
  });

  test('levels the workflow lacks fall back', () {
    final usual = workflow(['task', 'story', 'epic', 'bug', 'idea'], defaultType: 'idea');
    expect(NewItemDefaults.childType('task', usual), 'task', reason: 'no subtask: a task again');
    expect(NewItemDefaults.childType('epic', workflow(['task', 'epic'])), 'task', reason: 'no story');
    expect(NewItemDefaults.childType('epic', workflow(['bug', 'epic'], defaultType: 'bug')), 'bug');
  });

  test('parents to pick: unfinished, higher levels first; search by id or title', () {
    final candidates = NewItemDefaults.parentCandidates([
      item('B', type: 'task'),
      item('A', type: 'bug'),
      item('S', type: 'story'),
      item('E', type: 'epic'),
      item('D', type: 'epic', status: 'done'),
    ]);
    expect(candidates.map((i) => i.id), ['E', 'S', 'B', 'A']);
    expect(NewItemDefaults.search(candidates, 's').map((i) => i.id), ['S'], reason: 'ids match, and titles "Item …"');
    expect(NewItemDefaults.search(candidates, 'ITEM E').map((i) => i.id), ['E']);
    expect(NewItemDefaults.search(candidates, '', limit: 2), hasLength(2));
  });
}
