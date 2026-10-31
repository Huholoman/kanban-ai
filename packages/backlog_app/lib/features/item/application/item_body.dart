/// Helpers for the Markdown body of an item: its checklist (`- [ ] step`)
/// made interactive, and a plain-text excerpt for previews. Lines inside
/// fenced code blocks are never checklist items.
library;

/// A piece of a body: plain Markdown, or one checklist item.
sealed class BodySegment {
  const BodySegment();
}

/// Markdown between checklist items, rendered as it is.
final class MarkdownSegment extends BodySegment {
  const MarkdownSegment(this.markdown);

  final String markdown;
}

/// One `- [ ]` / `- [x]` line.
final class ChecklistSegment extends BodySegment {
  const ChecklistSegment({required this.index, required this.checked, required this.text, this.depth = 0});

  /// Position among the checklist items of the body, for [toggleChecklistItem].
  final int index;
  final bool checked;

  /// The item's text (inline Markdown).
  final String text;

  /// Nesting: the indentation in steps of two spaces.
  final int depth;
}

final _checkbox = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])(?:\s+(.*?))?\r?$');
final _fence = RegExp(r'^\s{0,3}(```|~~~)');

/// Splits [body] into Markdown and checklist items, in order.
List<BodySegment> splitChecklist(String body) {
  final segments = <BodySegment>[];
  final pending = <String>[];
  void flush() {
    if (pending.any((line) => line.trim().isNotEmpty)) segments.add(MarkdownSegment(pending.join('\n')));
    pending.clear();
  }

  var index = 0;
  for (final (line, isItem) in _lines(body)) {
    final match = isItem ? _checkbox.firstMatch(line) : null;
    if (match == null) {
      pending.add(line);
      continue;
    }
    flush();
    final indent = match.group(1)!.length - match.group(1)!.trimLeft().length;
    segments.add(
      ChecklistSegment(index: index++, checked: match.group(2) != ' ', text: match.group(4) ?? '', depth: indent ~/ 2),
    );
  }
  flush();
  return segments;
}

/// [body] with the checklist item at [index] checked or unchecked; every
/// other character stays as it was. Unchanged when there is no such item.
String toggleChecklistItem(String body, int index) {
  final lines = body.split('\n');
  var seen = 0;
  var position = 0;
  for (final (line, isItem) in _lines(body)) {
    final match = isItem ? _checkbox.firstMatch(line) : null;
    if (match != null && seen++ == index) {
      final mark = match.group(1)!.length; // the pattern is anchored at the line start
      lines[position] = line.replaceRange(mark, mark + 1, match.group(2) == ' ' ? 'x' : ' ');
      return lines.join('\n');
    }
    position++;
  }
  return body;
}

/// The first lines of prose in [body] as plain text: no headings, code,
/// list or quote markers, emphasis or checkboxes; empty when there is none.
String excerpt(String body, {int maxLines = 3}) {
  final kept = <String>[];
  var inFence = false;
  for (final raw in body.split('\n')) {
    if (_fence.hasMatch(raw)) {
      inFence = !inFence;
      continue;
    }
    final line = raw.trim();
    if (inFence || line.isEmpty || line.startsWith('#')) continue;
    final text = line
        .replaceFirst(RegExp(r'^(>\s*)+'), '')
        .replaceFirst(RegExp(r'^([-*+]|\d+[.)])\s+'), '')
        .replaceFirst(RegExp(r'^\[[ xX]\]\s+'), '')
        .replaceAll(RegExp(r'\*\*|__|`'), '')
        .trim();
    if (text.isEmpty) continue;
    kept.add(text);
    if (kept.length == maxLines) break;
  }
  return kept.join(' ');
}

/// Lines of [body], each with whether it may be a checklist item (i.e. it is
/// outside a fenced code block).
Iterable<(String, bool)> _lines(String body) sync* {
  var inFence = false;
  for (final line in body.split('\n')) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      yield (line, false);
    } else {
      yield (line, !inFence);
    }
  }
}
