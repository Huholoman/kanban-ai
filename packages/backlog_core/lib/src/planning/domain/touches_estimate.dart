import 'dart:convert';

import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../items/domain/path_glob.dart';

/// Port: the files of the code repository, as paths relative to its root.
abstract interface class RepoFiles {
  /// The paths; empty when there is no repository to ask.
  Future<List<String>> list();
}

/// Port: the model that answers the prompt of an estimate (a command of
/// `touches.suggest`).
abstract interface class TouchesModel {
  /// The model's answer to [prompt] about [item].
  Future<String> ask(Item item, String prompt);
}

/// A suggestion for the `touches` of an item, for a person to confirm.
final class TouchesEstimate {
  const TouchesEstimate({required this.item, required this.touches, this.rejected = const [], this.answer = ''});

  final Item item;

  /// The suggested paths and globs, in the order the model gave them.
  final List<String> touches;

  /// Entries of the answer left out, each with the reason.
  final List<({String entry, String reason})> rejected;

  /// The model's answer as it came.
  final String answer;
}

/// The pure parts of an estimate: the map of the repository, the prompt and
/// reading the answer.
abstract final class TouchesPrompt {
  /// At most this many entries are suggested.
  static const maxEntries = 20;

  /// The map of [files] in at most [limit] lines: every file when they fit,
  /// else the deepest level of folders that fits, deeper content collapsed
  /// into `folder/ (N files)` lines.
  static String repoMap(List<String> files, {int limit = 600}) {
    final paths = [
      for (final file in files)
        if (file.trim().isNotEmpty) file.trim(),
    ]..sort();
    if (paths.length <= limit) return paths.join('\n');
    final deepest = paths.fold(1, (max, path) => path.split('/').length > max ? path.split('/').length : max);
    var lines = _collapsed(paths, 1);
    for (var depth = 2; depth < deepest; depth++) {
      final deeper = _collapsed(paths, depth);
      if (deeper.length > limit) break;
      lines = deeper;
    }
    return lines.join('\n');
  }

  /// [paths] with everything below [depth] folders collapsed into one line
  /// per folder.
  static List<String> _collapsed(List<String> paths, int depth) {
    final counts = <String, int>{};
    for (final path in paths) {
      final segments = path.split('/');
      final key = segments.length <= depth ? path : '${segments.take(depth).join('/')}/';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return [
      for (final MapEntry(:key, value: count) in counts.entries)
        key.endsWith('/') ? '$key ($count ${count == 1 ? 'file' : 'files'})' : key,
    ];
  }

  /// The prompt for [item] with the repository map [map].
  static String render(Item item, String map) {
    final description = Discussion.split(item.body).description.trim();
    return '''
You estimate which files of a code repository the work on a backlog item will change, so that two agents never work on the same files at once.

Answer with paths or globs relative to the repository root, one per line, nothing else: no explanations, no numbering, no code fences. A folder (`lib/payments/`) covers everything in it, `*` matches within one path segment, `**` any number of segments, `{a,b}` lists alternatives. Prefer the narrowest folders or globs that cover the work, including tests and docs it has to change; give new files in the folder they will be created in. At most $maxEntries lines. Never answer `**` or `*` (the whole repository).

Item ${item.id}: ${item.title}
${description.isEmpty ? '(no description)' : description}

Files of the repository:
$map
''';
  }

  /// The entries of [answer] (one per line, or a JSON list of strings),
  /// checked against [files]: an entry must be a valid pattern that does
  /// not cover the whole repository, and match a file or name a file or
  /// folder in an existing folder. Without [files] every valid entry counts.
  static ({List<String> touches, List<({String entry, String reason})> rejected}) parse(
    String answer, {
    List<String> files = const [],
  }) {
    final touches = <String>[];
    final rejected = <({String entry, String reason})>[];
    final globs = <String>{};
    for (final entry in _entries(answer)) {
      if (!globs.add(entry)) continue;
      final problem = PathGlob.problem(entry) ?? (files.isEmpty ? null : _missing(entry, files));
      if (problem != null) {
        rejected.add((entry: entry, reason: problem));
      } else if (touches.length >= maxEntries) {
        rejected.add((entry: entry, reason: 'is one too many (at most $maxEntries)'));
      } else {
        touches.add(entry);
      }
    }
    return (touches: touches, rejected: rejected);
  }

  static String? _missing(String entry, List<String> files) {
    final glob = PathGlob(entry);
    if (files.any(glob.matches)) return null;
    final segments = entry.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (segments.length <= 1) return null; // a new file or folder at the top
    final parent = PathGlob('${segments.take(segments.length - 1).join('/')}/');
    return files.any(parent.matches) ? null : 'matches nothing in the repository';
  }

  static final _marker = RegExp(r'^(?:[-*+•]|\d+[.)])\s+');

  static Iterable<String> _entries(String answer) sync* {
    final text = answer.trim();
    final open = text.indexOf('['), close = text.lastIndexOf(']');
    if (open >= 0 && close > open && RegExp(r'^(```\w*)?$').hasMatch(text.substring(0, open).trim())) {
      try {
        final decoded = jsonDecode(text.substring(open, close + 1));
        if (decoded is List && decoded.every((e) => e is String)) {
          for (final entry in decoded.cast<String>()) {
            if (entry.trim().isNotEmpty) yield entry.trim();
          }
          return;
        }
      } on FormatException {
        // Not JSON; read it line by line.
      }
    }
    for (var line in LineSplitter.split(text)) {
      line = line.trim().replaceFirst(_marker, '');
      if (line.isEmpty || line.startsWith('```') || line.startsWith('#')) continue;
      // The first word is the path; whatever follows is a comment.
      var entry = line.split(RegExp(r'\s+')).first;
      entry = entry.replaceAll(RegExp('^[`\'"]+|[`\'",;:]+\$'), '');
      if (!RegExp(r'[\w*]').hasMatch(entry)) continue; // a lone list marker or punctuation
      if (!RegExp(r'[/.*{]').hasMatch(entry) && line.contains(' ')) continue; // prose
      yield entry;
    }
  }
}
