/// One entry of an item's `touches`: a path or glob relative to the root of
/// the code repository, e.g. `lib/payments/`, `lib/**/*.dart`, `pubspec.yaml`.
///
/// The question it answers is whether two items may change the same file, so
/// matching errs on the side of an overlap:
///
/// - a pattern also covers everything below what it matches, as in
///   `.gitignore`: `lib/foo`, `lib/foo/` and `lib/foo/**` are the same;
///   only a last segment that looks like a file name (`a.dart`, `*.yaml`: a
///   dot after the first character) without a trailing `/` is taken as files;
/// - `*` and `?` match within one path segment, `**` any number of segments;
/// - `{a,b}` lists alternatives, `[...]` counts as any one character, `\`
///   escapes the next character;
/// - a leading `/` or `./` is dropped, empty and `.` segments are ignored;
///   matching is case-sensitive.
///
/// Malformed patterns (an unclosed `[` or `{`) are read literally; [problem]
/// reports them for the linter.
final class PathGlob {
  factory PathGlob(String source) => PathGlob._(source, [for (final variant in _expand(source)) _parse(variant)]);

  PathGlob._(this.source, this._alternatives);

  final String source;

  /// Each alternative is a list of segments, usually ending with `**`.
  final List<List<_Segment>> _alternatives;

  /// Whether some path is covered by both this pattern and [other].
  bool overlaps(PathGlob other) => _alternatives.any((a) => other._alternatives.any((b) => _Overlap(a, b).check()));

  /// Whether the concrete [path] (or something below it) is covered.
  bool matches(String path) => overlaps(PathGlob._(path, [_literal(path)]));

  /// Whether any pattern of [a] overlaps any pattern of [b]; false when one
  /// of them is empty.
  static bool anyOverlap(Iterable<PathGlob> a, Iterable<PathGlob> b) => a.any((x) => b.any(x.overlaps));

  /// What is wrong with [source] as a `touches` entry, or null when nothing.
  static String? problem(String source) {
    final text = source.trim();
    if (text.isEmpty) return 'is empty';
    var squares = false, braces = 0;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == r'\') {
        if (i == text.length - 1) return 'ends with a lone backslash';
        i++;
      } else if (char == '[' && !squares) {
        squares = true;
      } else if (char == ']') {
        squares = false;
      } else if (char == '{' && !squares) {
        braces++;
      } else if (char == '}' && !squares) {
        if (braces == 0) return 'has a "}" without "{"';
        braces--;
      }
    }
    if (squares) return 'has an unclosed "["';
    if (braces > 0) return 'has an unclosed "{"';
    if (text.split('/').contains('..')) return 'points outside the repository ("..")';
    if (PathGlob(text)._alternatives.any((segments) => segments.every((s) => s is _AnySegments || s.isStar))) {
      return 'covers the whole repository';
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is PathGlob && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => source;

  /// Expands `{a,b}` groups (nested too) into separate patterns; an
  /// unbalanced group stays as it is.
  static List<String> _expand(String source) {
    final open = _findUnescaped(source, '{', 0);
    if (open < 0) return [source];
    var depth = 0;
    final commas = <int>[];
    for (var i = open; i < source.length; i++) {
      final char = source[i];
      if (char == r'\') {
        i++;
      } else if (char == '{') {
        depth++;
      } else if (char == ',' && depth == 1) {
        commas.add(i);
      } else if (char == '}' && --depth == 0) {
        final head = source.substring(0, open), tail = source.substring(i + 1);
        final bounds = [open, ...commas, i];
        return [
          for (var k = 0; k + 1 < bounds.length; k++)
            ..._expand('$head${source.substring(bounds[k] + 1, bounds[k + 1])}$tail'),
        ];
      }
    }
    // Unclosed: keep the brace literal and look further.
    return [for (final rest in _expand(source.substring(open + 1))) '${source.substring(0, open)}\\{$rest'];
  }

  static int _findUnescaped(String text, String char, int from) {
    for (var i = from; i < text.length; i++) {
      if (text[i] == r'\') {
        i++;
      } else if (text[i] == char) {
        return i;
      }
    }
    return -1;
  }

  static List<_Segment> _parse(String pattern) {
    final segments = <_Segment>[];
    for (final part in _splitPath(pattern.trim())) {
      if (part == '**') {
        if (segments.lastOrNull is! _AnySegments) segments.add(const _AnySegments());
        continue;
      }
      final tokens = <_Token>[];
      for (var i = 0; i < part.length; i++) {
        final char = part[i];
        if (char == r'\' && i + 1 < part.length) {
          tokens.add(_Char(part[++i]));
        } else if (char == '*') {
          if (tokens.lastOrNull is! _Star) tokens.add(const _Star());
        } else if (char == '?') {
          tokens.add(const _AnyChar());
        } else if (char == '[' && _classEnd(part, i) != null) {
          tokens.add(const _AnyChar());
          i = _classEnd(part, i)!;
        } else {
          tokens.add(_Char(char));
        }
      }
      segments.add(_Name(tokens));
    }
    return _withDescendants(segments, directory: pattern.trim().endsWith('/'));
  }

  static List<_Segment> _literal(String path) => _withDescendants([
    for (final part in _splitPath(path.trim())) _Name([for (final char in part.split('')) _Char(char)]),
  ], directory: path.trim().endsWith('/'));

  /// Adds the implicit `/**`, unless the last segment looks like a file name
  /// (`foo.dart`, `*.yaml`: a dot after the first character) and no `/`
  /// follows it. Without that exception `**/README.md` would overlap every
  /// path, because `lib/a.dart` could be a folder holding a README.md.
  static List<_Segment> _withDescendants(List<_Segment> segments, {required bool directory}) {
    final last = segments.lastOrNull;
    if (last is _AnySegments) return segments;
    if (!directory && last is _Name && last.looksLikeFile) return segments;
    return [...segments, const _AnySegments()];
  }

  /// Segments of a path without empty and `.` ones; an escaped `/` does not
  /// split.
  static List<String> _splitPath(String path) {
    final parts = <String>[];
    var current = StringBuffer();
    for (var i = 0; i < path.length; i++) {
      final char = path[i];
      if (char == r'\' && i + 1 < path.length) {
        current.write(path.substring(i, i + 2));
        i++;
      } else if (char == '/') {
        parts.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }
    parts.add(current.toString());
    return parts.where((part) => part.isNotEmpty && part != '.').toList();
  }

  /// Index of the `]` closing a class opened at [start], or null.
  static int? _classEnd(String part, int start) {
    var i = start + 1;
    if (i < part.length && (part[i] == '!' || part[i] == '^')) i++;
    if (i < part.length && part[i] == ']') i++;
    for (; i < part.length; i++) {
      if (part[i] == ']') return i;
    }
    return null;
  }
}

sealed class _Segment {
  const _Segment();

  bool get isStar => false;
}

/// `**`: zero or more whole segments.
final class _AnySegments extends _Segment {
  const _AnySegments();
}

/// One segment matched by a sequence of tokens.
final class _Name extends _Segment {
  const _Name(this.tokens);

  final List<_Token> tokens;

  @override
  bool get isStar => tokens.length == 1 && tokens.single is _Star;

  bool get looksLikeFile => tokens.skip(1).any((t) => t is _Char && t.char == '.');

  /// Whether some (non-empty) segment name matches both.
  bool overlaps(_Name other) {
    final a = tokens, b = other.tokens;
    final memo = <int, bool>{};
    bool from(int i, int j) => memo[i * (b.length + 1) + j] ??= () {
      if (i == a.length) return b.skip(j).every((t) => t is _Star);
      if (j == b.length) return a.skip(i).every((t) => t is _Star);
      final x = a[i], y = b[j];
      // A star absorbs whatever the other token stands for, or nothing.
      if (x is _Star) return from(i + 1, j) || from(i, j + 1);
      if (y is _Star) return from(i, j + 1) || from(i + 1, j);
      return x.accepts(y) && from(i + 1, j + 1);
    }();
    return from(0, 0);
  }
}

sealed class _Token {
  const _Token();

  /// Whether one character fits both this and [other] (neither is a star).
  bool accepts(_Token other) => switch ((this, other)) {
    (_Char(char: final a), _Char(char: final b)) => a == b,
    _ => true,
  };
}

final class _Char extends _Token {
  const _Char(this.char);

  final String char;
}

/// `?` or a `[...]` class.
final class _AnyChar extends _Token {
  const _AnyChar();
}

final class _Star extends _Token {
  const _Star();
}

/// Intersection of two segment lists: is there a path both accept?
final class _Overlap {
  _Overlap(this.a, this.b);

  final List<_Segment> a;
  final List<_Segment> b;
  final _memo = <int, bool>{};

  bool check() => _from(0, 0);

  bool _from(int i, int j) => _memo[i * (b.length + 1) + j] ??= () {
    if (i == a.length) return b.skip(j).every((s) => s is _AnySegments);
    if (j == b.length) return a.skip(i).every((s) => s is _AnySegments);
    final x = a[i], y = b[j];
    if (x is _AnySegments) return _from(i + 1, j) || _from(i, j + 1);
    if (y is _AnySegments) return _from(i, j + 1) || _from(i + 1, j);
    return (x as _Name).overlaps(y as _Name) && _from(i + 1, j + 1);
  }();
}
