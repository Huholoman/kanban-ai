import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/features/board/application/column_arrangement.dart';
import 'package:flutter_test/flutter_test.dart';

ItemDto node(String id, {String? parent, String type = 'task'}) =>
    ItemDto(id: id, title: id, type: type, status: 'todo', priority: 'p2', parent: parent);

List<String> layout(List<ItemDto> column, [List<ItemDto> others = const []]) => ColumnArrangement.arrange(column, {
  for (final item in [...column, ...others]) item.id: item,
}).map((entry) => entry.toString()).toList();

void main() {
  test('children follow their parent, indented', () {
    final epic = node('E', type: 'epic');
    expect(layout([node('A'), epic, node('S1', parent: 'E'), node('S2', parent: 'E')]), ['A', 'E', '  S1', '  S2']);
  });

  test('a parent from another column becomes a context header', () {
    final epic = node('E', type: 'epic');
    expect(layout([node('S1', parent: 'E'), node('X'), node('S2', parent: 'E')], [epic]), [
      'E (context)',
      '  S1',
      '  S2',
      'X',
    ]);
  });

  test('nested parents keep their depth', () {
    expect(layout([node('T1', parent: 'S'), node('S', parent: 'E')], [node('E', type: 'epic')]), [
      'E (context)',
      '  S',
      '    T1',
    ]);
  });

  test('unknown parents and parent cycles do not lose items', () {
    expect(layout([node('A', parent: 'GONE')]), ['GONE (context)', '  A']);
    expect(layout([node('A', parent: 'B'), node('B', parent: 'A')]), hasLength(2));
  });

  test('a collapsed parent hides everything nested under it and counts it', () {
    final items = [node('E', type: 'epic'), node('S', parent: 'E'), node('T', parent: 'S'), node('X')];
    final index = {for (final item in items) item.id: item};

    final open = ColumnArrangement.arrange(items, index);
    expect(open.map((e) => (e.item.id, e.descendants)), [('E', 2), ('S', 1), ('T', 0), ('X', 0)]);

    final epicFolded = ColumnArrangement.arrange(items, index, collapsed: {'E'});
    expect(epicFolded.map((e) => e.toString()), ['E (+2 collapsed)', 'X']);

    final storyFolded = ColumnArrangement.arrange(items, index, collapsed: {'S', 'X'});
    expect(storyFolded.map((e) => e.toString()), ['E', '  S (+1 collapsed)', 'X'], reason: 'leaves cannot fold');
  });
}
