import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

void main() {
  const codec = MarkdownItemCodec(ItemDefaults(type: 'task', status: 'backlog', priority: 'p2'));

  const handWritten = '''
---
# Written by hand, comments must survive.
id: T-8m2x
title: "Content reporting: DSA minimum (naïve ✓)"
status: in-progress
priority: p0
labels: [moderation, legal]
depends_on:
  - T-1abc
estimate: 3d          # custom key
---

## Remaining
- [x] Report button
- [ ] Handle reports
''';

  test('decodes known fields, defaults and unknown keys', () {
    final item = codec.decode(handWritten);
    expect(item.id, ItemId('T-8m2x'));
    expect(item.title, 'Content reporting: DSA minimum (naïve ✓)');
    expect(item.type, 'task');
    expect(item.status, 'in-progress');
    expect(item.dependsOn, [ItemId('T-1abc')]);
    expect(item.labels, ['moderation', 'legal']);
    expect(item.extra, {'estimate': '3d'});
    expect(item.body, startsWith('## Remaining'));
    expect(item.checklist.toString(), '1/2');
  });

  test('an unchanged item is written back byte for byte', () {
    expect(codec.update(handWritten, codec.decode(handWritten)), handWritten);
  });

  test('updates touch only changed keys and keep comments, order and body', () {
    final item = codec.decode(handWritten);
    final updated = codec.update(
      handWritten,
      item.copyWith(status: 'done', labels: [...item.labels, 'dsa'], assignee: () => 'agent-2'),
    );
    expect(updated, contains('# Written by hand, comments must survive.'));
    expect(updated, contains('status: done\n'));
    expect(updated, contains('labels: [moderation, legal, dsa]'));
    expect(updated, contains('assignee: agent-2'));
    expect(updated, contains('estimate: 3d          # custom key'));
    expect(updated, contains('title: "Content reporting: DSA minimum (naïve ✓)"'));
    expect(updated, endsWith('- [ ] Handle reports\n'));
    expect(updated.indexOf('id:'), lessThan(updated.indexOf('status:')));
    expect(codec.decode(updated).status, 'done');
  });

  test('clearing a field removes its key', () {
    final item = codec.decode(handWritten);
    final updated = codec.update(handWritten, item.copyWith(labels: [], dependsOn: []));
    expect(updated, isNot(contains('labels')));
    expect(updated, isNot(contains('depends_on')));
    expect(updated, contains('estimate'));
  });

  test('a new file round-trips, quoting values YAML would misread', () {
    final item = Item(
      id: ItemId('T-0001'),
      title: 'Fix: colon # and hash',
      type: 'bug',
      status: 'todo',
      priority: 'p1',
      labels: ['yes', '42', 'a,b', 'ok'],
      branch: 'feat/reports',
      extra: {
        'estimate': 3,
        'links': {'pr': 'https://example.com/pr/1'},
      },
      body: '## Kontext\n\nText.',
    );
    final text = codec.encode(item);
    expect(text, startsWith('---\nid: T-0001\ntitle: "Fix: colon # and hash"\n'));
    expect(text, contains('labels: ["yes", "42", "a,b", ok]'));
    expect(text, contains('branch: feat/reports'));
    final decoded = codec.decode(text);
    expect(decoded.title, item.title);
    expect(decoded.labels, item.labels);
    expect(decoded.extra, {
      'estimate': 3,
      'links': {'pr': 'https://example.com/pr/1'},
    });
    expect(decoded.body, '## Kontext\n\nText.\n');
  });

  test('reports files it cannot read', () {
    expect(() => codec.decode('# just markdown'), throwsFormatException);
    expect(() => codec.decode('---\ntitle: no id\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: T-1\ntitle: x\nstatus: [a]\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: T-1\ntitle: x\nparent: "bad id"\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: [\n---\n'), throwsFormatException);
  });
}
