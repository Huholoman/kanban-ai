import '../../shared/errors.dart';

/// One comment of an item's discussion.
final class Comment {
  Comment({required String author, required this.at, required String text, this.question = false, this.note = false})
    : author = _author(author),
      text = text.trim() {
    if (this.text.isEmpty) throw const InvalidInputException('A comment needs some text.');
    if (question && note) throw const InvalidInputException('A comment is either a question or a note.');
  }

  /// Who wrote it: an agent (its worktree name) or a person.
  final String author;

  /// When, to the second (UTC).
  final DateTime at;

  /// Markdown.
  final String text;

  /// An agent asks a person and waits for the answer ([Discussion.openQuestion]).
  final bool question;

  /// Only a note: it does not answer an open question and does not wake the
  /// item's agent ([Discussion.after] leaves it out); a resumed agent sees it
  /// as context.
  final bool note;

  static String _author(String author) {
    final name = author.replaceAll(RegExp(r'\s+'), ' ').replaceAll('·', '-').trim();
    if (name.isEmpty) throw const InvalidInputException('A comment needs an author.');
    return name;
  }

  /// `### <author> · 2026-10-31 14:05:12 UTC` (with ` · question` or
  /// ` · note`).
  String get heading =>
      '### $author · ${_stamp(at)}${question
          ? ' · question'
          : note
          ? ' · note'
          : ''}';

  static String _stamp(DateTime time) {
    final utc = time.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
  }
}

/// The `## Discussion` section at the end of an item's body: comments of
/// agents and people, oldest first, each under a heading line
///
/// ```markdown
/// ## Discussion
///
/// ### monorepo-2 · 2026-10-31 14:05:12 UTC · question
///
/// CSV or JSON for the export?
///
/// ### tobik · 2026-10-31 14:20:03 UTC
///
/// CSV.
///
/// ### tobik · 2026-10-31 15:02:41 UTC · note
///
/// The export format may change next quarter.
/// ```
///
/// Plain Markdown, so it reads well in the file and in git and can be edited
/// by hand. The section runs from its heading to the next heading of level 1
/// or 2 (or the end); a comment from its heading line to the next one. Text
/// before the first comment heading and lines in code fences are never
/// structure. Seconds and ` UTC` may be left out of hand-written headings.
final class Discussion {
  const Discussion(this.comments);

  static const empty = Discussion([]);

  static const heading = '## Discussion';

  final List<Comment> comments;

  bool get isEmpty => comments.isEmpty;

  /// The latest question no one else has answered yet (an answer is any
  /// later comment of another author that is not a [Comment.note]); null
  /// when there is none.
  Comment? get openQuestion {
    Comment? open;
    for (final comment in comments) {
      if (comment.question) {
        open = comment;
      } else if (open != null && comment.author != open.author && !comment.note) {
        open = null;
      }
    }
    return open;
  }

  /// Comments written after [time] by someone other than [except], notes
  /// ([Comment.note]) only when [notes].
  List<Comment> after(DateTime time, {String? except, bool notes = false}) => [
    for (final comment in comments)
      if (comment.at.isAfter(time) && comment.author != except && (notes || !comment.note)) comment,
  ];

  static final _sectionHeading = RegExp(r'^##\s+Discussion\s*$', caseSensitive: false);
  static final _higherHeading = RegExp(r'^#{1,2}\s');
  static final _commentHeading = RegExp(
    r'^###\s+(.+?)\s+·\s+(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d(?::\d\d)?)(?:\s*(?:UTC|Z))?(?:\s+·\s+(question|note))?\s*$',
  );
  static final _fence = RegExp(r'^\s{0,3}(```|~~~)');

  /// The discussion in [body]; empty without a `## Discussion` section.
  static Discussion parse(String body) {
    if (!body.contains(RegExp(r'^##\s+Discussion', multiLine: true, caseSensitive: false))) return empty;
    final lines = body.split('\n');
    final section = _section(lines);
    if (section == null) return empty;
    final comments = <Comment>[];
    ({String author, DateTime at, bool question, bool note})? current;
    final text = <String>[];
    void flush() {
      final head = current;
      final joined = text.join('\n').trim();
      if (head != null && joined.isNotEmpty) {
        comments.add(Comment(author: head.author, at: head.at, text: joined, question: head.question, note: head.note));
      }
      text.clear();
    }

    var inFence = false;
    for (var i = section.start + 1; i < section.end; i++) {
      final line = lines[i];
      if (_fence.hasMatch(line)) inFence = !inFence;
      final match = inFence ? null : _commentHeading.firstMatch(line.trimRight());
      final at = match == null ? null : DateTime.tryParse('${match[2]}T${match[3]}Z');
      if (match != null && at != null) {
        flush();
        current = (author: match[1]!, at: at, question: match[4] == 'question', note: match[4] == 'note');
      } else if (current != null) {
        text.add(line);
      }
    }
    flush();
    return Discussion(List.unmodifiable(comments));
  }

  /// [body] with [comment] added at the end of its discussion (a new
  /// `## Discussion` section at the end of the body when there is none).
  /// Everything else stays as it was. Headings of level 1–3 in the comment
  /// become level 4, so that they do not end the comment or the section.
  static String append(String body, Comment comment) {
    final entry = '${comment.heading}\n\n${_demoteHeadings(comment.text)}\n';
    final lines = body.split('\n');
    final section = _section(lines);
    if (section == null) {
      final before = body.trimRight();
      return '${before.isEmpty ? '' : '$before\n\n'}$heading\n\n$entry';
    }
    var end = section.end;
    while (end > section.start + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    final head = lines.sublist(0, end).join('\n');
    final rest = lines.sublist(section.end);
    final tail = rest.join('\n');
    return '$head\n\n$entry${rest.isEmpty || tail.trim().isEmpty ? '' : '\n$tail'}';
  }

  /// [body] without its discussion section; the description part.
  static String withoutDiscussion(String body) {
    final lines = body.split('\n');
    final section = _section(lines);
    if (section == null) return body;
    final before = lines.sublist(0, section.start).join('\n').trimRight();
    final after = lines.sublist(section.end).join('\n').trim();
    return [before, after].where((part) => part.isNotEmpty).join('\n\n');
  }

  /// Line range of the section: its heading and the end (exclusive).
  static ({int start, int end})? _section(List<String> lines) {
    int? start;
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      if (start == null) {
        if (_sectionHeading.hasMatch(line.trimRight())) start = i;
      } else if (_higherHeading.hasMatch(line)) {
        return (start: start, end: i);
      }
    }
    return start == null ? null : (start: start, end: lines.length);
  }

  static String _demoteHeadings(String text) {
    final heading = RegExp(r'^#{1,3}(?=\s)');
    var inFence = false;
    final lines = <String>[];
    for (final line in text.split('\n')) {
      if (_fence.hasMatch(line)) inFence = !inFence;
      lines.add(inFence ? line : line.replaceFirst(heading, '####'));
    }
    return lines.join('\n');
  }
}
