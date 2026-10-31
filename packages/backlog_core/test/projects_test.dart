import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ProjectRegistry', () {
    test('derives ids from the project folder, named by the parent for `backlog`', () {
      expect(ProjectRegistry.deriveId('/p/kanban-ai/backlog'), 'kanban-ai');
      expect(ProjectRegistry.deriveId('/p/Hobbyo Backlog'), 'hobbyo-backlog');
      expect(ProjectRegistry.deriveId('/backlog'), 'backlog');
      expect(ProjectEntry.at('/p/Žluťák/backlog').displayName, 'Žluťák');
      expect(ProjectEntry.at('/p/Žluťák/backlog').id, 'zlutak');
    });

    test('refuses invalid and repeated ids, repeated folders', () {
      expect(
        () => ProjectRegistry([const ProjectEntry(id: 'Bad Id', path: '/a')]),
        throwsA(isA<ConfigurationException>()),
      );
      expect(
        () => ProjectRegistry([ProjectEntry.at('/a/x/backlog'), ProjectEntry.at('/b/x')]),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains('"x" is used twice'))),
      );
      final registry = ProjectRegistry([ProjectEntry.at('/a/x/backlog')]);
      expect(() => registry.add(ProjectEntry.at('/a/x/backlog', id: 'y')), throwsA(isA<InvalidInputException>()));
      expect(() => registry.add(ProjectEntry.at('/b/x')), throwsA(isA<InvalidInputException>()));
      expect(registry.uniqueIdFor('/b/x'), 'x-2');
      expect(registry.add(ProjectEntry.at('/b/x', id: 'x-2')).entries.map((e) => e.id), ['x', 'x-2']);
      expect(() => registry.remove('nope'), throwsA(isA<NotFoundException>()));
      expect(registry.defaultProject!.id, 'x');
    });
  });

  test('projectRegistryFile: BACKLOG_PROJECTS, XDG_CONFIG_HOME, then ~/.config', () {
    expect(projectRegistryFile({'BACKLOG_PROJECTS': '/etc/p.yaml', 'XDG_CONFIG_HOME': '/x'}), '/etc/p.yaml');
    expect(projectRegistryFile({'XDG_CONFIG_HOME': '/x', 'HOME': '/h'}), '/x/kanban-ai/projects.yaml');
    expect(projectRegistryFile({'HOME': '/h'}), '/h/.config/kanban-ai/projects.yaml');
    expect(projectRegistryFile({}), isNull);
  });

  group('YAML registry', () {
    late Directory dir;
    late String file;
    late ProjectService service;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('backlog_projects_');
      file = p.join(dir.path, 'config', 'projects.yaml');
      service = ProjectService(YamlProjectRegistryStore(file, home: p.join(dir.path, 'home')));
    });

    tearDown(() => dir.delete(recursive: true));

    test('a missing file is an empty registry; add creates it', () async {
      expect((await service.registry()).isEmpty, isTrue);
      final first = await service.add(p.join(dir.path, 'home', 'p', 'kanban-ai', 'backlog'));
      final second = await service.add(p.join(dir.path, 'elsewhere', 'kanban-ai'), name: 'Copy');
      expect(first.id, 'kanban-ai');
      expect(second.id, 'kanban-ai-2');
      final text = File(file).readAsStringSync();
      expect(text, startsWith('# Backlogs served by backlog-server'));
      expect(text, contains('path: ~/p/kanban-ai/backlog'));
      expect(text, contains('name: Copy'));
      final registry = await service.registry();
      expect(registry.entries, [first, second]);
      expect(registry.entries.last.displayName, 'Copy');
    });

    test('reads ~, relative paths and optional keys; edits keep comments', () async {
      File(file)
        ..createSync(recursive: true)
        ..writeAsStringSync('''
# my projects
projects:
  - path: ~/p/hobbyo/backlog   # the app
  - id: tools
    name: Tools
    path: ../tools
    pinned: true
    color: red                 # unknown keys are kept
''');
      final registry = await service.registry();
      expect(registry.entries.map((e) => (e.id, e.displayName, e.path, e.pinned)), [
        ('hobbyo', 'hobbyo', p.join(dir.path, 'home', 'p', 'hobbyo', 'backlog'), false),
        ('tools', 'Tools', p.join(dir.path, 'tools'), true),
      ]);

      await service.add(p.join(dir.path, 'new'));
      await service.remove('hobbyo');
      final text = File(file).readAsStringSync();
      expect(text, contains('# my projects'));
      expect(text, contains('color: red                 # unknown keys are kept'));
      expect(text, contains('pinned: true'));
      expect((await service.registry()).entries.map((e) => e.pinned), [true, false]);
      expect(text, isNot(contains('hobbyo')));
      expect((await service.registry()).entries.map((e) => e.id), ['tools', 'new']);
      expect(() => service.remove('hobbyo'), throwsA(isA<NotFoundException>()));
    });

    test('pin and unpin write `pinned` and keep the rest', () async {
      File(file)
        ..createSync(recursive: true)
        ..writeAsStringSync('''
projects:
  - path: ~/p/a      # first
  - id: b
    path: ../b
    pinned: true
    color: red
''');
      expect((await service.setPinned('a', true)).pinned, isTrue);
      expect((await service.setPinned('b', false)).pinned, isFalse);
      expect((await service.setPinned('b', false)).pinned, isFalse, reason: 'unpinning twice changes nothing');
      expect((await service.registry()).entries.map((e) => (e.id, e.pinned)), [('a', true), ('b', false)]);
      final text = File(file).readAsStringSync();
      expect(text, contains('# first'));
      expect(text, contains('color: red'));
      expect(text, isNot(contains('pinned: false')), reason: 'unpinned entries drop the key');
      expect(() => service.setPinned('nope', true), throwsA(isA<NotFoundException>()));
    });

    test('an empty list gets its first entry', () async {
      File(file)
        ..createSync(recursive: true)
        ..writeAsStringSync('# none yet\nprojects: []\n');
      await service.add(p.join(dir.path, 'a'));
      expect((await service.registry()).entries.map((e) => e.id), ['a']);
      expect(File(file).readAsStringSync(), contains('# none yet'));
    });

    test('malformed files are configuration errors', () async {
      File(file).createSync(recursive: true);
      for (final source in [
        'projects: {a: 1}',
        'projects:\n  - id: x\n',
        '- a\n',
        'projects: [{path: a}, {path: b/a}]',
        'projects: [{path: a, pinned: maybe}]',
      ]) {
        File(file).writeAsStringSync(source);
        expect(service.registry(), throwsA(isA<ConfigurationException>()), reason: source);
      }
    });
  });
}
