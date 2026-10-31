import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

import 'support.dart';

Comment _comment(String author, int minute, String text, {bool question = false, bool note = false}) =>
    Comment(author: author, at: DateTime.utc(2026, 10, 31, 14, minute, 7), text: text, question: question, note: note);

void main() {
  group('Discussion', () {
    test('appends a section at the end of the body and parses it back', () {
      const body = '## Context\n\nExport the report.\n\n- [ ] CSV\n';
      final asked = Discussion.append(body, _comment('w2', 5, 'CSV or JSON?', question: true));
      expect(
        asked,
        '## Context\n\nExport the report.\n\n- [ ] CSV\n\n'
        '## Discussion\n\n'
        '### w2 · 2026-10-31 14:05:07 UTC · question\n\nCSV or JSON?\n',
      );
      final answered = Discussion.append(asked, _comment('tobik', 20, 'CSV.\n\nAnd a header row.'));
      expect(answered, startsWith(asked));
      expect(answered.substring(asked.length), '\n### tobik · 2026-10-31 14:20:07 UTC\n\nCSV.\n\nAnd a header row.\n');

      final discussion = Discussion.parse(answered);
      expect(discussion.comments.map((c) => (c.author, c.text, c.question)), [
        ('w2', 'CSV or JSON?', true),
        ('tobik', 'CSV.\n\nAnd a header row.', false),
      ]);
      expect(discussion.comments.first.at, DateTime.utc(2026, 10, 31, 14, 5, 7));
      expect(Discussion.withoutDiscussion(answered), body.trimRight());
      expect(Discussion.append('', _comment('a', 1, 'x')), '## Discussion\n\n### a · 2026-10-31 14:01:07 UTC\n\nx\n');
    });

    test('an open question is answered by a later comment of someone else', () {
      Discussion of(List<Comment> comments) => Discussion(comments);
      final question = _comment('w2', 1, 'Which?', question: true);
      expect(of([question]).openQuestion, same(question));
      expect(of([question, _comment('w2', 2, 'Also: which file?')]).openQuestion, same(question));
      expect(of([question, _comment('tobik', 3, 'This one.')]).openQuestion, isNull);
      final again = _comment('w2', 4, 'And then?', question: true);
      expect(of([question, _comment('tobik', 3, 'This one.'), again]).openQuestion, same(again));
      expect(of([_comment('tobik', 1, 'Why so?')]).openQuestion, isNull, reason: 'comments are not questions');
    });

    test('a note is marked in its heading, answers no question and is left out of replies unless asked for', () {
      final question = _comment('w2', 1, 'Which?', question: true);
      final body = Discussion.append(
        Discussion.append('', question),
        _comment('tobik', 2, 'Thinking about it.', note: true),
      );
      expect(body, endsWith('### tobik · 2026-10-31 14:02:07 UTC · note\n\nThinking about it.\n'));
      final parsed = Discussion.parse(body);
      expect(parsed.comments.map((c) => (c.author, c.question, c.note)), [('w2', true, false), ('tobik', false, true)]);
      expect(parsed.openQuestion!.text, 'Which?', reason: 'a note does not answer');
      final since = DateTime.utc(2026, 10, 31, 14);
      expect(parsed.after(since, except: 'w2'), isEmpty);
      expect(parsed.after(since, except: 'w2', notes: true).single.text, 'Thinking about it.');

      // Old and hand-written headings still parse; an unknown marker is no heading.
      final old = Discussion.parse(
        '## Discussion\n\n### tobik · 2026-10-31 14:05\n\nPlain.\n\n### tobik · 2026-10-31 14:06 · note\n\nN.\n',
      );
      expect(old.comments.map((c) => (c.text, c.note)), [('Plain.', false), ('N.', true)]);
      expect(
        () => Comment(author: 'a', at: since, text: 'x', question: true, note: true),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('keeps text after the section and hand-written comments; code fences are never structure', () {
      const body =
          '## Context\n\nText.\n\n'
          '## Discussion\n\n'
          'Intro text is ignored.\n\n'
          '### tobik · 2026-10-31 09:15\n\n'
          'Hand-written, no seconds.\n\n'
          '```\n## Not a heading\n### fake · 2026-10-31 10:00:00 UTC\n```\n\n'
          '## Notes\n\nKept.\n';
      final discussion = Discussion.parse(body);
      expect(discussion.comments.single.author, 'tobik');
      expect(discussion.comments.single.at, DateTime.utc(2026, 10, 31, 9, 15));
      expect(discussion.comments.single.text, contains('### fake'));

      final added = Discussion.append(body, _comment('w2', 0, '## My plan\n\n```\n# code\n```'));
      expect(added, endsWith('## Notes\n\nKept.\n'), reason: 'what follows the section stays');
      expect(
        added,
        contains('```\n\n### w2 · 2026-10-31 14:00:07 UTC\n\n#### My plan\n\n```\n# code\n```\n\n## Notes'),
      );
      expect(Discussion.parse(added).comments.last.text, '#### My plan\n\n```\n# code\n```');
      expect(Discussion.withoutDiscussion(added), '## Context\n\nText.\n\n## Notes\n\nKept.');
    });

    test('authors and text are cleaned up; empty ones are refused', () {
      expect(Comment(author: ' a · b\n', at: DateTime.utc(2026), text: ' x ').heading, startsWith('### a - b · '));
      expect(() => Comment(author: 'a', at: DateTime.utc(2026), text: '  '), throwsA(isA<InvalidInputException>()));
      expect(() => Comment(author: ' ', at: DateTime.utc(2026), text: 'x'), throwsA(isA<InvalidInputException>()));
      expect(Discussion.parse('No section.\n').isEmpty, isTrue);
    });
  });

  group('needs a person', () {
    test('an open question makes the item need a person and not ready, until answered', () async {
      final (backlog, clock) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'Export', status: 'todo', body: '## Context\n\nExport it.\n'));
      await backlog.items.comment('T-0001', author: 'w2', text: 'CSV or JSON?', question: true);

      var snapshot = await backlog.planning.snapshot();
      final planned = snapshot[ItemId('T-0001')]!;
      expect(planned.needsHuman, isTrue);
      expect(planned.isReady, isFalse);
      expect(snapshot.needingHuman.single.id, ItemId('T-0001'));
      expect(ItemFields.valuesOf(planned, 'needs_human'), ['true']);
      expect(await backlog.claims.claimNext('w1'), isNull, reason: 'next skips it');

      final file = File((await backlog.items.locate('T-0001'))!).readAsStringSync();
      expect(
        file,
        contains('## Context\n\nExport it.\n\n## Discussion\n\n### w2 · 2026-10-29 12:00:00 UTC · question'),
      );

      clock.advance(const Duration(minutes: 3));
      await backlog.items.comment('T-0001', author: 'tobik', text: 'CSV.');
      snapshot = await backlog.planning.snapshot();
      expect(snapshot[ItemId('T-0001')]!.needsHuman, isFalse);
      expect(snapshot[ItemId('T-0001')]!.isReady, isTrue);

      await backlog.items.comment('T-0001', author: 'w2', text: 'Why?', question: true);
      await backlog.claims.complete('T-0001', force: true);
      expect(
        (await backlog.planning.snapshot())[ItemId('T-0001')]!.needsHuman,
        isFalse,
        reason: 'done items wait for nobody',
      );
    });

    test('item snapshots read a discussion only when the body has one', () {
      final snapshot = snapshotOf([
        item('T-1', body: '## Discussion\n\n### a · 2026-10-31 10:00 UTC · question\n\nQ?\n'),
      ]);
      expect(snapshot.items.single.needsHuman, isTrue);
      expect(snapshotOf([item('T-1', body: 'plain')]).items.single.needsHuman, isFalse);
    });
  });
}
