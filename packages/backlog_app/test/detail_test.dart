import 'package:backlog_app/features/item/application/detail_navigation.dart';
import 'package:backlog_app/features/item/application/item_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetailNavigation', () {
    test('open remembers the way, back walks it in reverse', () {
      var navigation = const DetailNavigation('E-1');
      expect(navigation.canGoBack, isFalse);
      navigation = navigation.open('S-1').open('T-1');
      expect(navigation.current, 'T-1');
      expect(navigation.history, ['E-1', 'S-1']);
      navigation = navigation.back();
      expect(navigation, const DetailNavigation('S-1', ['E-1']));
      expect(navigation.back().back(), const DetailNavigation('E-1'), reason: 'back at the start stays');
    });

    test('going to the item just left is going back, the same item is no move', () {
      final navigation = const DetailNavigation('S-1').open('T-1');
      expect(navigation.open('S-1'), const DetailNavigation('S-1'));
      expect(navigation.open('T-1'), same(navigation));
    });

    test('replace swaps the item without a history entry', () {
      final navigation = const DetailNavigation('E-1').open('S-1').replace('S-2');
      expect(navigation, const DetailNavigation('S-2', ['E-1']));
    });
  });

  group('SiblingPosition', () {
    test('knows its neighbours and prints as "2 / 3"', () {
      final middle = SiblingPosition.of(['A', 'B', 'C'], 'B')!;
      expect('$middle', '2 / 3');
      expect((middle.previous, middle.next), ('A', 'C'));
      final first = SiblingPosition.of(['A', 'B', 'C'], 'A')!;
      expect((first.previous, first.next), (null, 'B'));
      expect(SiblingPosition.of(['A', 'B', 'C'], 'C')!.next, isNull);
      expect(SiblingPosition.of(['A'], 'X'), isNull);
    });
  });

  group('item body', () {
    const body =
        '## Plan\n- [x] pick a tool\n  - [ ] nested step\n```\n- [ ] not an item\n```\n1. [ ] numbered\r\nend\n';

    test('toggleChecklistItem flips one box and keeps everything else', () {
      expect(toggleChecklistItem(body, 0), body.replaceFirst('- [x] pick', '- [ ] pick'));
      expect(toggleChecklistItem(body, 1), body.replaceFirst('- [ ] nested', '- [x] nested'));
      expect(toggleChecklistItem(body, 2), body.replaceFirst('1. [ ]', '1. [x]'), reason: 'code fences are skipped');
      expect(toggleChecklistItem(body, 3), body);
      expect(toggleChecklistItem('- [X] upper', 0), '- [ ] upper');
    });

    test('splitChecklist cuts the body into Markdown and numbered checklist items', () {
      final segments = splitChecklist(body);
      expect(segments.map((s) => s.runtimeType), [
        MarkdownSegment,
        ChecklistSegment,
        ChecklistSegment,
        MarkdownSegment,
        ChecklistSegment,
        MarkdownSegment,
      ]);
      final items = segments.whereType<ChecklistSegment>().toList();
      expect(items.map((i) => (i.index, i.checked, i.text, i.depth)), [
        (0, true, 'pick a tool', 0),
        (1, false, 'nested step', 1),
        (2, false, 'numbered', 0),
      ]);
      expect((segments[3] as MarkdownSegment).markdown, contains('not an item'));
    });

    test('excerpt is the first lines of prose as plain text', () {
      expect(
        excerpt('## Context\nRun a **full** restore.\n\n- time it\n```\ncode\n```\n> quoted\nmore'),
        'Run a full restore. time it quoted',
      );
      expect(excerpt('# Only a heading'), '');
    });
  });
}
