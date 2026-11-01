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

  test('rank is a number; a value that is not one makes the file unreadable', () {
    final item = codec.decode(handWritten);
    expect(item.rank, isNull);
    final ranked = codec.update(handWritten, item.copyWith(rank: () => 1536));
    expect(ranked, contains('rank: 1536\n'));
    expect(codec.decode(ranked).rank, 1536);
    expect(codec.decode(ranked.replaceFirst('rank: 1536', 'rank: 7.25')).rank, 7.25);
    expect(codec.decode(codec.encode(item.copyWith(rank: () => 2048))).rank, 2048);
    expect(codec.update(ranked, item), handWritten);
    expect(() => codec.decode(ranked.replaceFirst('rank: 1536', 'rank: high')), throwsFormatException);
    expect(() => codec.decode(ranked.replaceFirst('rank: 1536', 'rank: .nan')), throwsFormatException);
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

  test('touches round-trip as globs, through new files and updates', () {
    final globs = ['lib/payments/', '**/*.dart', 'lib/*.{dart,yaml}', '*.md'];
    final fresh = Item(
      id: ItemId('T-0002'),
      title: 'Payments',
      type: 'task',
      status: 'todo',
      priority: 'p1',
      touches: globs,
    );
    expect(codec.decode(codec.encode(fresh)).touches, globs);

    final item = codec.decode(handWritten);
    final updated = codec.update(handWritten, item.copyWith(touches: globs));
    expect(updated, contains('# Written by hand, comments must survive.'));
    expect(codec.decode(updated).touches, globs);
    expect(codec.decode(updated).extra, {'estimate': '3d'});
    expect(codec.update(updated, item), handWritten);
  });

  test('reports files it cannot read', () {
    expect(() => codec.decode('# just markdown'), throwsFormatException);
    expect(() => codec.decode('---\ntitle: no id\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: T-1\ntitle: x\nstatus: [a]\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: T-1\ntitle: x\nparent: "bad id"\n---\n'), throwsFormatException);
    expect(() => codec.decode('---\nid: [\n---\n'), throwsFormatException);
  });

  test('times are written plain in UTC; a day from an older file stays as it is', () {
    const old = '---\nid: T-1\ntitle: x\ncreated: 2026-10-30\nupdated: 2026-10-30\n---\n';
    final item = codec.decode(old);
    expect(item.createdAt, DateTime.utc(2026, 10, 30));
    final changed = codec.update(
      old,
      item.copyWith(updated: () => ItemTime.format(DateTime.utc(2026, 10, 31, 20, 27, 12))),
    );
    expect(changed, '---\nid: T-1\ntitle: x\ncreated: 2026-10-30\nupdated: 2026-10-31T20:27:12Z\n---\n');
    expect(codec.decode(changed).updatedAt, DateTime.utc(2026, 10, 31, 20, 27, 12));
    expect(codec.encode(codec.decode(changed)), contains('updated: 2026-10-31T20:27:12Z\n'));
  });

  test('ItemTime reads instants, days and times without a zone, and orders them', () {
    expect(ItemTime.format(DateTime.utc(2026, 1, 2, 3, 4, 5, 600)), '2026-01-02T03:04:05Z');
    expect(ItemTime.parse('2026-10-31T22:27:12+02:00'), DateTime.utc(2026, 10, 31, 20, 27, 12));
    expect(ItemTime.parse('2026-10-31T20:27'), DateTime.utc(2026, 10, 31, 20, 27));
    expect(ItemTime.parse('2026-10-31'), DateTime.utc(2026, 10, 31));
    expect(ItemTime.parse('soon'), isNull);
    expect(ItemTime.hasTime('2026-10-31'), isFalse);
    expect(ItemTime.hasTime('2026-10-31T20:27:12Z'), isTrue);
    final sorted = ['2026-10-31T08:00:00Z', null, 'soon', '2026-10-30', '2026-10-31T06:00:00+02:00']
      ..sort(ItemTime.compare);
    expect(sorted, ['2026-10-30', '2026-10-31T06:00:00+02:00', '2026-10-31T08:00:00Z', 'soon', null]);
  });
}
