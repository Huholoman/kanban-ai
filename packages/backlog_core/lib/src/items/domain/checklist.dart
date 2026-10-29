/// Progress derived from Markdown task-list lines (`- [ ]` / `- [x]`) in an
/// item body. Lines inside fenced code blocks are ignored.
final class Checklist {
  const Checklist(this.done, this.total);

  factory Checklist.parse(String markdown) {
    var done = 0;
    var total = 0;
    var inFence = false;
    for (final line in markdown.split('\n')) {
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final match = _task.firstMatch(line);
      if (match == null) continue;
      total++;
      if (match.group(1) != ' ') done++;
    }
    return Checklist(done, total);
  }

  static final _fence = RegExp(r'^\s*(```|~~~)');
  static final _task = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]');

  final int done;
  final int total;

  bool get isEmpty => total == 0;

  @override
  String toString() => '$done/$total';
}
