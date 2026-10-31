import '../../shared/errors.dart';

/// Progress derived from Markdown task-list lines (`- [ ]` / `- [x]`) in an
/// item body. Lines inside fenced code blocks are ignored.
final class Checklist {
  const Checklist(this.done, this.total);

  factory Checklist.parse(String markdown) {
    final entries = entriesOf(markdown);
    return Checklist(entries.where((entry) => entry.done).length, entries.length);
  }

  /// The checklist lines of [markdown] in order, numbered from 1; the same
  /// lines [Checklist.parse] counts.
  static List<ChecklistEntry> entriesOf(String markdown) {
    final entries = <ChecklistEntry>[];
    var inFence = false;
    final lines = markdown.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final match = _task.firstMatch(line);
      if (match == null) continue;
      entries.add(
        ChecklistEntry(
          number: entries.length + 1,
          text: line.substring(match.end).trim(),
          done: match.group(2) != ' ',
          line: index,
        ),
      );
    }
    return entries;
  }

  /// The entry [selector] names: its number (`2`), else its text — the one
  /// whose text equals it, ignoring case, or else the only one containing it.
  static ChecklistEntry select(List<ChecklistEntry> entries, String selector) {
    final wanted = selector.trim();
    if (wanted.isEmpty) throw const InvalidInputException('Name a checklist item by its number or text.');
    if (int.tryParse(wanted) case final number? when RegExp(r'^\d+$').hasMatch(wanted)) {
      if (number >= 1 && number <= entries.length) return entries[number - 1];
      throw NotFoundException(
        entries.isEmpty
            ? 'The item has no checklist.'
            : 'No checklist item $number; the checklist has ${entries.length} item(s).',
      );
    }
    final lower = wanted.toLowerCase();
    final exact = entries.where((entry) => entry.text.toLowerCase() == lower).toList();
    final matches = exact.isNotEmpty ? exact : entries.where((e) => e.text.toLowerCase().contains(lower)).toList();
    if (matches.length == 1) return matches.single;
    if (matches.isEmpty) throw NotFoundException('No checklist item matches "$wanted".');
    throw InvalidInputException(
      '"$wanted" matches ${matches.length} checklist items (${matches.map((e) => '${e.number}. ${e.text}').join('; ')}); '
      'name one by its number.',
    );
  }

  /// [markdown] with [entries] checked ([done]) or unchecked; only their
  /// box characters change, every other character stays as it was.
  static String mark(String markdown, Iterable<ChecklistEntry> entries, {required bool done}) {
    final lines = markdown.split('\n');
    for (final entry in entries) {
      final line = lines[entry.line];
      final match = _task.firstMatch(line);
      if (match == null) throw StateError('Line ${entry.line} is no checklist item.');
      final box = match.start + match.group(0)!.lastIndexOf('[') + 1;
      lines[entry.line] = line.replaceRange(box, box + 1, done ? 'x' : ' ');
    }
    return lines.join('\n');
  }

  static final _fence = RegExp(r'^\s*(```|~~~)');
  static final _task = RegExp(r'^\s*([-*+]|\d+[.)])\s+\[([ xX])\]');

  final int done;
  final int total;

  bool get isEmpty => total == 0;

  @override
  String toString() => '$done/$total';
}

/// One checklist line of a body.
final class ChecklistEntry {
  const ChecklistEntry({required this.number, required this.text, required this.done, required this.line});

  /// Position in the checklist, from 1.
  final int number;

  /// What follows the box, trimmed (inline Markdown).
  final String text;
  final bool done;

  /// Index of the line in the body (0-based).
  final int line;

  @override
  String toString() => '$number. [${done ? 'x' : ' '}] $text';
}
