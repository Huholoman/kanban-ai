import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('TouchesPrompt', () {
    test('the repository map lists every file when they fit, else folders as deep as fit', () {
      const files = ['lib/a/x.dart', 'lib/a/y.dart', 'lib/b/z.dart', 'README.md', 'test/a_test.dart'];
      expect(TouchesPrompt.repoMap(files), 'README.md\nlib/a/x.dart\nlib/a/y.dart\nlib/b/z.dart\ntest/a_test.dart');
      expect(TouchesPrompt.repoMap(files, limit: 4), 'README.md\nlib/a/ (2 files)\nlib/b/ (1 file)\ntest/a_test.dart');
      expect(TouchesPrompt.repoMap(files, limit: 3), 'README.md\nlib/ (3 files)\ntest/ (1 file)');
      expect(TouchesPrompt.repoMap(const []), '');
    });

    test('the prompt has the title, the description without the discussion and the map', () {
      final prompt = TouchesPrompt.render(
        item('T-1', body: 'Export to CSV.\n\n## Discussion\n\n### a · 2026-10-31 10:00:00 UTC\n\nSecret.\n'),
        'lib/a.dart',
      );
      expect(prompt, contains('Item T-1: Item T-1\nExport to CSV.\n'));
      expect(prompt, isNot(contains('Secret')));
      expect(prompt, endsWith('Files of the repository:\nlib/a.dart\n'));
      expect(TouchesPrompt.render(item('T-2'), ''), contains('(no description)'));
    });

    test('reads one entry per line, without list markers, quotes and comments', () {
      const answer = '''
Here are the files:
```
- `lib/payments/`
2. lib/**/*.dart  # all Dart files
* "pubspec.yaml",
Makefile
lib/payments/
```
''';
      final (:touches, :rejected) = TouchesPrompt.parse(answer);
      expect(touches, ['lib/payments/', 'lib/**/*.dart', 'pubspec.yaml', 'Makefile']);
      expect(rejected, isEmpty);
    });

    test('reads a JSON list, also in a code fence', () {
      expect(TouchesPrompt.parse('["lib/a/", "test/a_test.dart"]').touches, ['lib/a/', 'test/a_test.dart']);
      expect(TouchesPrompt.parse('```json\n["lib/a/"]\n```').touches, ['lib/a/']);
    });

    test('rejects malformed patterns, the whole repository and paths in no existing folder', () {
      const files = ['lib/a/x.dart', 'README.md'];
      final (:touches, :rejected) = TouchesPrompt.parse(
        'lib/a/\nlib/a/new.dart\nlib/{a\n**\n../x\nsrc/main.c\nCHANGELOG.md\nlib/*.dart',
        files: files,
      );
      expect(touches, ['lib/a/', 'lib/a/new.dart', 'CHANGELOG.md', 'lib/*.dart']);
      expect(
        {for (final r in rejected) r.entry: r.reason},
        {
          'lib/{a': 'has an unclosed "{"',
          '**': 'covers the whole repository',
          '../x': 'points outside the repository ("..")',
          'src/main.c': 'matches nothing in the repository',
        },
      );
    });

    test('suggests at most ${TouchesPrompt.maxEntries} entries', () {
      final answer = [for (var i = 0; i < 25; i++) 'lib/f$i.dart'].join('\n');
      final (:touches, :rejected) = TouchesPrompt.parse(answer);
      expect(touches, hasLength(TouchesPrompt.maxEntries));
      expect(rejected, hasLength(5));
    });
  });

  group('touches.suggest', () {
    Future<Directory> repository() async {
      final dir = await Directory.systemTemp.createTemp('touches_repo_');
      addTearDown(() => dir.delete(recursive: true));
      Future<void> git(List<String> args) async {
        final result = await Process.run('git', [
          '-c',
          'user.name=T',
          '-c',
          'user.email=t@example.com',
          ...args,
        ], workingDirectory: dir.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await git(['init', '-q', '-b', 'main']);
      for (final path in ['lib/payments/pay.dart', 'lib/users/user.dart', 'README.md']) {
        await File(p.join(dir.path, path)).create(recursive: true);
      }
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'one']);
      await git(['checkout', '-q', '-b', 'other']);
      await File(p.join(dir.path, 'only-on-other.txt')).create();
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'two']);
      return dir;
    }

    test('GitRepoFiles lists the files of the base branch, else of HEAD', () async {
      final repo = await repository();
      final files = await GitRepoFiles([p.join(repo.path, 'missing'), repo.path]).list();
      expect(files, unorderedEquals(['README.md', 'lib/payments/pay.dart', 'lib/users/user.dart']));
      expect(await GitRepoFiles([repo.path], base: 'trunk').list(), contains('only-on-other.txt'));
      final notGit = await Directory.systemTemp.createTemp('no_git_');
      addTearDown(() => notGit.delete(recursive: true));
      expect(await GitRepoFiles([notGit.path]).list(), isEmpty);
    });

    test('parses the section; it is optional', () {
      expect(parseWorkflowYaml('statuses:').touches, isNull);
      final config = parseWorkflowYaml(
        'touches:\n  suggest: llm -m mini {prompt}\n  repo: ../code\n  timeout: 30\n',
      ).touches!;
      expect(config.suggest.arguments, ['llm', '-m', 'mini', '{prompt}']);
      expect((config.repo, config.timeout, config.promptInArguments), ('../code', const Duration(seconds: 30), true));
      expect(parseWorkflowYaml('touches:\n  suggest: [ollama, run, qwen]').touches!.promptInArguments, isFalse);
      for (final (yaml, message) in [
        ('touches:\n  repo: x', 'touches.suggest is required'),
        ('touches:\n  suggest: x\n  model: y', 'unknown key "touches.model"'),
        ('touches:\n  suggest: x {path}', 'unknown placeholder "{path}"'),
        ('touches:\n  suggest: x\n  timeout: 0', 'touches.timeout must be positive'),
      ]) {
        expect(
          () => parseWorkflowYaml(yaml),
          throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
          reason: yaml,
        );
      }
    });

    test('runs the command in the code repository with the prompt and checks its answer', () async {
      final repo = await repository();
      final (plain, _) = await tempBacklog();
      expect(plain.touches, isNull);
      final config = await File(p.join(plain.root, 'backlog.yaml')).readAsString();
      final script =
          'cat > "{backlog}/prompt.txt"; pwd > "{backlog}/pwd.txt"; '
          'printf "lib/payments/\\nsrc/nowhere.c\\nlib/payments/refund.dart\\n"';
      await File(
        p.join(plain.root, 'backlog.yaml'),
      ).writeAsString('$config\ntouches:\n  repo: ${repo.path}\n  suggest: [sh, -c, \'$script\']\n');
      final backlog = await Backlog.open(plain.root, ids: SequentialIds());
      final created = await backlog.items.create(const NewItem(title: 'Refunds', body: 'Refund a payment.'));
      final estimate = await backlog.touches!.estimate(created.id.value);
      expect(estimate.touches, ['lib/payments/', 'lib/payments/refund.dart']);
      expect(estimate.rejected.map((r) => r.entry), ['src/nowhere.c']);
      final prompt = await File(p.join(backlog.root, 'prompt.txt')).readAsString();
      expect(prompt, contains('Item ${created.id}: Refunds\nRefund a payment.'));
      expect(prompt, contains('lib/payments/pay.dart\nlib/users/user.dart'));
      expect(prompt, isNot(contains('only-on-other.txt')));
      expect((await File(p.join(backlog.root, 'pwd.txt')).readAsString()).trim(), await repo.resolveSymbolicLinks());
      expect((await backlog.items.get(created.id.value)).touches, isEmpty, reason: 'an estimate saves nothing');
    });

    test('a failing command is unavailable, with the end of its error output', () async {
      final (plain, _) = await tempBacklog();
      final config = await File(p.join(plain.root, 'backlog.yaml')).readAsString();
      await File(
        p.join(plain.root, 'backlog.yaml'),
      ).writeAsString('$config\ntouches:\n  suggest: [sh, -c, "echo no model >&2; exit 3"]\n');
      final backlog = await Backlog.open(plain.root, ids: SequentialIds());
      final created = await backlog.items.create(const NewItem(title: 'X'));
      await expectLater(
        backlog.touches!.estimate(created.id.value),
        throwsA(isA<UnavailableException>().having((e) => e.message, 'message', contains('exit code 3: no model'))),
      );
    });
  });
}
