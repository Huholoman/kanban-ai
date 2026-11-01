import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

void main() {
  const discussion = '## Discussion\n\n### w1 · 2026-10-29 12:00:00 UTC · question\n\nCSV?\n';

  group('ItemBody.withDescription', () {
    test('replaces everything above the discussion and keeps it', () {
      expect(
        ItemBody.withDescription('Old text.\n\n## Plan\n\n- [ ] a\n\n$discussion', '\nNew text.\n\n'),
        'New text.\n\n$discussion',
      );
    });

    test('without a discussion it is the whole body; empty text keeps only the discussion', () {
      expect(ItemBody.withDescription('Old.\n', 'New.'), 'New.\n');
      expect(ItemBody.withDescription('Old.\n\n$discussion', ''), discussion);
      expect(ItemBody.withDescription('', ''), '');
    });
  });

  group('ItemBody.withSection', () {
    const body = 'Intro.\n\n## Acceptance criteria\n\n- old\n\n## Notes\n\nKeep.\n\n';

    test('replaces the content of the section up to the next heading of level 2', () {
      expect(
        ItemBody.withSection('$body$discussion', 'acceptance CRITERIA', '- new\n- more'),
        'Intro.\n\n## Acceptance criteria\n\n- new\n- more\n\n## Notes\n\nKeep.\n\n$discussion',
      );
    });

    test('subsections and fenced code belong to the section', () {
      const fenced = '## Plan\n\n### Step\n\n```\n## not a heading\n```\n\n## Next\n\nx\n';
      expect(ItemBody.withSection(fenced, 'Plan', 'Done.'), '## Plan\n\nDone.\n\n## Next\n\nx\n');
    });

    test('a missing section is added at the end of the description, before the discussion', () {
      expect(
        ItemBody.withSection('Intro.\n\n$discussion', 'Acceptance criteria', '- works'),
        'Intro.\n\n## Acceptance criteria\n\n- works\n\n$discussion',
      );
      expect(ItemBody.withSection('', 'Plan', 'a'), '## Plan\n\na\n');
    });

    test('the discussion is never a section to replace', () {
      expect(ItemBody.isSectionName(' discussion '), isFalse);
      expect(ItemBody.isSectionName(''), isFalse);
      expect(ItemBody.isSectionName('Plan'), isTrue);
      expect(() => ItemBody.withSection('Intro.\n\n$discussion', 'Discussion', 'x'), throwsArgumentError);
    });

    test('a text with a discussion section is no description', () {
      expect(ItemBody.isDescription('New.\n\n$discussion'), isFalse);
      expect(ItemBody.isDescription('New.\n\n## discussion\n'), isFalse);
      expect(ItemBody.isDescription('New.\n\n```\n## Discussion\n```\n\n### Discussion\n'), isTrue);
      expect(() => ItemBody.withDescription('Old.\n\n$discussion', 'New.\n\n$discussion'), throwsArgumentError);
      expect(() => ItemBody.withSection('Old.\n\n$discussion', 'Plan', 'a\n\n$discussion'), throwsArgumentError);
    });
  });
}
