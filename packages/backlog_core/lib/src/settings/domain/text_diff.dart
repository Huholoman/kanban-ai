/// What happened to one line between two versions of a text.
enum DiffKind { same, added, removed, skipped }

/// One line of a line diff; [DiffKind.skipped] stands for unchanged lines
/// left out by [diffHunks] (its [text] says how many).
final class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffKind kind;
  final String text;

  /// The line as in a unified diff: `+`, `-`, ` ` or `…` in front.
  String get marked => switch (kind) {
    DiffKind.same => ' $text',
    DiffKind.added => '+$text',
    DiffKind.removed => '-$text',
    DiffKind.skipped => '… $text',
  };

  @override
  bool operator ==(Object other) => other is DiffLine && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => marked;
}

/// Every line of [before] and [after] as kept, removed or added (a longest
/// common subsequence; removals come before additions at each change).
List<DiffLine> diffLines(String before, String after) {
  final a = _lines(before);
  final b = _lines(after);
  // Trim the common head and tail so that the table only covers the change.
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final x = a.sublist(head, a.length - tail);
  final y = b.sublist(head, b.length - tail);
  // lengths[i][j]: the longest common subsequence of x[i..] and y[j..].
  final lengths = List.generate(x.length + 1, (_) => List.filled(y.length + 1, 0));
  for (var i = x.length - 1; i >= 0; i--) {
    for (var j = y.length - 1; j >= 0; j--) {
      lengths[i][j] = x[i] == y[j]
          ? lengths[i + 1][j + 1] + 1
          : (lengths[i + 1][j] >= lengths[i][j + 1] ? lengths[i + 1][j] : lengths[i][j + 1]);
    }
  }
  final middle = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] == y[j]) {
      middle.add(DiffLine(DiffKind.same, x[i++]));
      j++;
    } else if (i < x.length && (j == y.length || lengths[i + 1][j] >= lengths[i][j + 1])) {
      middle.add(DiffLine(DiffKind.removed, x[i++]));
    } else {
      middle.add(DiffLine(DiffKind.added, y[j++]));
    }
  }
  return [
    for (final line in a.take(head)) DiffLine(DiffKind.same, line),
    ...middle,
    for (final line in a.skip(a.length - tail)) DiffLine(DiffKind.same, line),
  ];
}

/// [diffLines] with only [context] unchanged lines around each change; the
/// rest collapses into [DiffKind.skipped] lines. Empty when nothing changed.
List<DiffLine> diffHunks(String before, String after, {int context = 3}) {
  final all = diffLines(before, after);
  final changed = [
    for (final (index, line) in all.indexed)
      if (line.kind != DiffKind.same) index,
  ];
  if (changed.isEmpty) return const [];
  bool near(int index) => changed.any((c) => (c - index).abs() <= context);
  final result = <DiffLine>[];
  var skipped = 0;
  void flush() {
    if (skipped == 0) return;
    result.add(DiffLine(DiffKind.skipped, skipped == 1 ? '1 unchanged line' : '$skipped unchanged lines'));
    skipped = 0;
  }

  for (final (index, line) in all.indexed) {
    if (line.kind != DiffKind.same || near(index)) {
      flush();
      result.add(line);
    } else {
      skipped++;
    }
  }
  flush();
  return result;
}

List<String> _lines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (text.endsWith('\n')) lines.removeLast();
  return lines;
}
