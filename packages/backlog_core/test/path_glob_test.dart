import 'dart:math';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

void main() {
  bool overlap(String a, String b) {
    final forward = PathGlob(a).overlaps(PathGlob(b));
    expect(PathGlob(b).overlaps(PathGlob(a)), forward, reason: 'overlap must be symmetric for "$a" and "$b"');
    return forward;
  }

  group('PathGlob.overlaps', () {
    test('identical and nested literal paths overlap', () {
      expect(overlap('lib/foo.dart', 'lib/foo.dart'), isTrue);
      expect(overlap('lib/foo', 'lib/foo/bar.dart'), isTrue);
      expect(overlap('lib/foo/', 'lib/foo/bar/baz.dart'), isTrue);
      expect(overlap('lib/foo/**', 'lib/foo/bar.dart'), isTrue);
      expect(overlap('lib', 'lib/foo/**'), isTrue);
    });

    test('siblings and prefixes of names do not overlap', () {
      expect(overlap('lib/foo.dart', 'lib/bar.dart'), isFalse);
      expect(overlap('lib/foo', 'lib/foobar'), isFalse);
      expect(overlap('lib/foo/', 'test/foo/'), isFalse);
      expect(overlap('pubspec.yaml', 'pubspec.lock'), isFalse);
    });

    test('a leading slash, ./, empty and . segments are ignored', () {
      expect(overlap('/lib/foo', './lib/foo/a.dart'), isTrue);
      expect(overlap('lib//foo/./a.dart', 'lib/foo/a.dart'), isTrue);
      expect(overlap('./lib/a', '/lib/b'), isFalse);
    });

    test('* and ? stay within one segment', () {
      expect(overlap('lib/*.dart', 'lib/foo.dart'), isTrue);
      expect(overlap('lib/*.dart', 'lib/foo/bar.dart'), isFalse);
      expect(overlap('lib/*.dart', 'lib/foo.yaml'), isFalse);
      expect(overlap('lib/f?o.dart', 'lib/foo.dart'), isTrue);
      expect(overlap('lib/f?o.dart', 'lib/fo.dart'), isFalse);
      // A bare * also covers what is below the directories it matches.
      expect(overlap('lib/*', 'lib/foo/bar.dart'), isTrue);
    });

    test('** spans any number of segments, including none', () {
      expect(overlap('lib/**/*.dart', 'lib/a.dart'), isTrue);
      expect(overlap('lib/**/*.dart', 'lib/a/b/c.dart'), isTrue);
      expect(overlap('lib/**/*.dart', 'test/a.dart'), isFalse);
      expect(overlap('**/README.md', 'docs/guide/README.md'), isTrue);
      expect(overlap('**/README.md', 'docs/guide/index.md'), isFalse);
      expect(overlap('**', 'anything/at/all'), isTrue);
    });

    test('two wildcard patterns overlap when some path fits both', () {
      expect(overlap('lib/*.dart', 'lib/foo*'), isTrue);
      expect(overlap('lib/*_test.dart', 'lib/foo_*'), isTrue);
      expect(overlap('lib/a*', 'lib/b*'), isFalse);
      expect(overlap('lib/*.dart', 'lib/*.yaml'), isFalse);
      expect(overlap('**/*.dart', 'packages/**/lib/x.dart'), isTrue);
      expect(overlap('*/lib/*.dart', 'packages/*/x.yaml'), isFalse);
      expect(overlap('a/**/b', '**/c'), isTrue); // a/b/c, since a/**/b covers below b
      expect(overlap('a/**/*.md', '**/*.dart'), isFalse);
    });

    test('{a,b} alternatives, also with slashes and nesting', () {
      expect(overlap('{lib,test}/foo.dart', 'test/foo.dart'), isTrue);
      expect(overlap('{lib,test}/foo.dart', 'bin/foo.dart'), isFalse);
      expect(overlap('lib/*.{dart,yaml}', 'lib/x.yaml'), isTrue);
      expect(overlap('lib/*.{dart,yaml}', 'lib/x.json'), isFalse);
      expect(overlap('{a/b,c/{d,e}}', 'c/e/f'), isTrue);
      expect(overlap('{a/b,c/{d,e}}', 'c/f'), isFalse);
    });

    test('a character class counts as any character (conservative)', () {
      expect(overlap('lib/[ab].dart', 'lib/a.dart'), isTrue);
      expect(overlap('lib/[!ab].dart', 'lib/a.dart'), isTrue);
      expect(overlap('lib/[ab].dart', 'lib/ab.dart'), isFalse);
    });

    test('malformed patterns are read literally', () {
      expect(overlap('lib/[x', 'lib/[x'), isTrue);
      expect(overlap('lib/[x', 'lib/x'), isFalse);
      expect(overlap('lib/{x', 'lib/{x/y'), isTrue);
      expect(overlap('lib/{x', 'lib/x'), isFalse);
    });

    test('escapes make wildcards literal', () {
      expect(overlap(r'lib/\*.dart', 'lib/a.dart'), isFalse);
      expect(overlap(r'lib/\*.dart', 'lib/*.dart'), isTrue);
    });

    test('a last segment that looks like a file name has nothing below it', () {
      expect(overlap('lib/a.dart', 'lib/a.dart/x'), isFalse);
      expect(overlap('**/README.md', 'docs/guide/index.md'), isFalse);
      expect(overlap('lib/foo.d/', 'lib/foo.d/x.conf'), isTrue);
      expect(overlap('.github', '.github/workflows/ci.yml'), isTrue);
      expect(overlap('Makefile', 'Makefile/x'), isTrue);
    });

    test('anyOverlap compares sets and is false for an empty set', () {
      final a = [PathGlob('lib/a/'), PathGlob('docs/')];
      expect(PathGlob.anyOverlap(a, [PathGlob('test/'), PathGlob('docs/x.md')]), isTrue);
      expect(PathGlob.anyOverlap(a, [PathGlob('test/')]), isFalse);
      expect(PathGlob.anyOverlap(a, const []), isFalse);
    });
  });

  test('matches tells whether a concrete path is covered', () {
    expect(PathGlob('lib/**/*.dart').matches('lib/a/b.dart'), isTrue);
    expect(PathGlob('lib/foo/').matches('lib/foo/bar.dart'), isTrue);
    expect(PathGlob('lib/*.dart').matches('lib/a/b.dart'), isFalse);
    expect(PathGlob('lib/a*').matches('lib/*'), isFalse);
  });

  test('problem reports malformed and suspicious patterns', () {
    expect(PathGlob.problem('lib/foo/'), isNull);
    expect(PathGlob.problem('lib/**/*.{dart,yaml}'), isNull);
    expect(PathGlob.problem('lib/[ab].dart'), isNull);
    expect(PathGlob.problem(' '), contains('empty'));
    expect(PathGlob.problem('lib/[ab'), contains('['));
    expect(PathGlob.problem('lib/{a,b'), contains('{'));
    expect(PathGlob.problem('lib/a}'), contains('}'));
    expect(PathGlob.problem(r'lib\'), contains('backslash'));
    expect(PathGlob.problem('../other/lib'), contains('outside'));
    expect(PathGlob.problem('**'), contains('whole repository'));
    expect(PathGlob.problem('*'), contains('whole repository'));
    expect(PathGlob.problem('.'), contains('whole repository'));
  });

  group('against brute force', () {
    // Small random patterns over a tiny alphabet, checked against a regular
    // expression evaluated on every path up to three short segments.
    final random = Random(42);
    final names = ['a', 'b', '.', 'ab', 'ba', 'a.', '.a', 'b.', '..', 'aa'].where((n) => n != '.').toList();
    final paths = <List<String>>[
      for (final x in names) ...[
        [x],
        for (final y in names) ...[
          [x, y],
          for (final z in names) [x, y, z],
        ],
      ],
    ];

    String randomPattern() {
      final segments = <String>[];
      for (var i = random.nextInt(3); i >= 0; i--) {
        if (random.nextInt(5) == 0) {
          segments.add('**');
        } else {
          var name = '';
          for (var j = random.nextInt(3); j >= 0; j--) {
            name += ['a', 'b', '.', '*', '?'][random.nextInt(5)];
          }
          segments.add(name == '.' ? 'a' : name);
        }
      }
      return segments.join('/');
    }

    RegExp regexOf(String pattern) {
      final buffer = StringBuffer('^');
      for (final segment in pattern.split('/')) {
        if (segment == '**') {
          buffer.write('(?:[^/]+/)*');
          continue;
        }
        for (final char in segment.split('')) {
          buffer.write(switch (char) {
            '*' => '[^/]*',
            '?' => '[^/]',
            _ => RegExp.escape(char),
          });
        }
        buffer.write('/');
      }
      return RegExp('$buffer\$');
    }

    bool looksLikeFile(String name) => !name.contains('*') && !name.contains('?') && name.indexOf('.', 1) > 0;

    bool fileLike(String pattern) {
      final last = pattern.split('/').last;
      return last != '**' && last.substring(1).contains('.');
    }

    // Path q is covered when the pattern matches it, or (for patterns that
    // can be folders) one of its parents.
    bool covers(String pattern, List<String> path) {
      final regex = regexOf(pattern);
      for (var k = path.length; k >= 1; k--) {
        if (k < path.length && fileLike(pattern)) break;
        if (regex.hasMatch('${path.take(k).join('/')}/')) return true;
      }
      return false;
    }

    final patterns = {for (var i = 0; i < 150; i++) randomPattern()}.toList();
    final covered = {
      for (final pattern in patterns)
        pattern: {
          for (final (i, path) in paths.indexed)
            if (covers(pattern, path)) i,
        },
    };

    test('a path both cover always means an overlap', () {
      for (final a in patterns) {
        for (final b in patterns) {
          if (covered[a]!.intersection(covered[b]!).isNotEmpty) {
            expect(PathGlob(a).overlaps(PathGlob(b)), isTrue, reason: '"$a" and "$b"');
          }
        }
      }
    });

    test('matches agrees on concrete file paths', () {
      for (final pattern in patterns) {
        for (final (i, path) in paths.indexed) {
          if (!looksLikeFile(path.last)) continue;
          expect(
            PathGlob(pattern).matches(path.join('/')),
            covered[pattern]!.contains(i),
            reason: '"$pattern" on $path',
          );
        }
      }
    });
  });
}
