import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String registry;
  late BacklogServer server;
  late HttpProjectsApi api;
  final logs = <String>[];

  Matcher apiError(int status, String type) =>
      isA<BacklogApiException>().having((e) => e.statusCode, 'statusCode', status).having((e) => e.type, 'type', type);

  Future<String> backlogAt(String name, String prefix) async {
    final root = p.join(dir.path, name, 'backlog');
    await Backlog.init(root, idPrefix: prefix);
    return root;
  }

  /// Polls [check] until it stops throwing (registry and file changes are
  /// picked up asynchronously).
  Future<void> eventually(FutureOr<void> Function() check) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await check();
        return;
      } catch (_) {
        if (attempt >= 100) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  setUp(() async {
    logs.clear();
    dir = await Directory.systemTemp.createTemp('backlog_projects_');
    await backlogAt('alpha', 'A');
    await backlogAt('beta', 'B');
    final broken = await backlogAt('broken', 'X');
    File(p.join(broken, 'backlog.yaml')).writeAsStringSync('statuses: [unclosed');
    registry = p.join(dir.path, 'config', 'projects.yaml');
    File(registry)
      ..createSync(recursive: true)
      ..writeAsStringSync('''
# test registry
projects:
  - path: ../alpha/backlog
  - id: b
    name: Beta
    path: ../beta/backlog
  - path: ../broken/backlog
  - id: gone
    path: ../nowhere
''');
    server = await BacklogServer.start(
      projectsFile: registry,
      addresses: [InternetAddress.loopbackIPv4],
      port: 0,
      token: 'secret',
      debounce: const Duration(milliseconds: 50),
      log: logs.add,
    );
    api = HttpProjectsApi(server.uri, token: 'secret');
  });

  tearDown(() async {
    api.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  test('lists the projects in registry order, broken ones with their error', () async {
    final projects = await api.projects();
    expect(projects.map((project) => (project.id, project.name)), [
      ('alpha', 'alpha'),
      ('b', 'Beta'),
      ('broken', 'broken'),
      ('gone', 'nowhere'),
    ]);
    expect(projects.first.path, p.join(dir.path, 'alpha', 'backlog'));
    expect(projects.take(2).map((project) => project.isAvailable), [true, true]);
    expect(projects[2].error, isNotNull);
    expect(projects[3].error, contains('does not exist'));
  });

  test('routes /api/p/<id>/… to the project and unprefixed paths to the default one', () async {
    final alpha = api.project('alpha');
    final beta = api.project('b');
    final created = await beta.createItem(const NewItemRequest(title: 'In beta'));
    expect(created.item.id, startsWith('B-'));
    expect((await beta.items()).map((item) => item.title), ['In beta']);
    expect(await alpha.items(), isEmpty);
    expect((await beta.item(created.item.id)).item.title, 'In beta');
    expect(await beta.views(), isNotEmpty);

    final fallback = HttpBacklogApi(server.uri, token: 'secret');
    addTearDown(fallback.close);
    await fallback.createItem(const NewItemRequest(title: 'In alpha'));
    expect((await alpha.items()).map((item) => item.title), ['In alpha']);
    expect((await fallback.workflow()).priorities, isNotEmpty);
  });

  test('each project reads its own files; edits on disk and of backlog.yaml are seen', () async {
    final alpha = api.project('alpha');
    final beta = api.project('b');
    void write(String project, String id, String title) => File(
      p.join(dir.path, project, 'backlog', 'items', 'same-name.md'),
    ).writeAsStringSync('---\nid: $id\ntitle: $title\n---\n');

    write('alpha', 'A-1', 'Alpha 1');
    write('beta', 'B-1', 'Beta 1');
    expect((await alpha.items()).map((item) => item.title), ['Alpha 1']);
    expect((await beta.items()).map((item) => item.title), ['Beta 1']);
    write('alpha', 'A-1', 'Alpha 2');
    expect((await alpha.items()).map((item) => item.title), ['Alpha 2']);
    expect((await beta.items()).map((item) => item.title), ['Beta 1']);

    final config = File(p.join(dir.path, 'beta', 'backlog', 'backlog.yaml'));
    config.writeAsStringSync(config.readAsStringSync().replaceFirst('priority: p2', 'priority: p0'));
    await eventually(() async => expect((await beta.items()).single.priority, 'p0'));
    expect((await alpha.items()).single.priority, 'p2');
  });

  test('unknown projects are not_found; broken ones answer with their error; the token applies', () async {
    expect(() => api.project('nope').items(), throwsA(apiError(404, 'not_found')));
    expect(() => api.project('broken').items(), throwsA(apiError(500, 'configuration')));
    expect(() => api.project('gone').items(), throwsA(apiError(404, 'not_found')));
    expect(() => HttpProjectsApi(server.uri).projects(), throwsA(apiError(401, 'unauthorized')));
    expect(() => HttpProjectsApi(server.uri).project('b').items(), throwsA(apiError(401, 'unauthorized')));
    final health = await http.get(server.uri.replace(path: ApiPaths.health));
    expect(jsonDecode(health.body), {'ok': true});
    expect((await http.get(server.uri.replace(path: '/api/p/b/health'))).statusCode, 401);
  });

  test('PATCH /api/projects/<id> pins a project in the registry file', () async {
    expect((await api.projects()).map((project) => project.pinned), everyElement(isFalse));
    final pinned = await api.setPinned('b', true);
    expect((pinned.id, pinned.name, pinned.pinned), ('b', 'Beta', true));
    expect((await api.projects()).map((project) => project.pinned), [false, true, false, false]);
    final text = File(registry).readAsStringSync();
    expect(text, contains('# test registry'));
    expect(text, contains('pinned: true'));
    expect((await api.setPinned('b', false)).pinned, isFalse);
    expect(File(registry).readAsStringSync(), isNot(contains('pinned')));
    await expectLater(api.setPinned('nope', true), throwsA(apiError(404, 'not_found')));
  });

  test('change events arrive on the socket of their project only', () async {
    final alphaEvents = <BacklogChangeEvent>[];
    final alpha = api.project('alpha').changes().listen(alphaEvents.add);
    addTearDown(alpha.cancel);
    final beta = StreamIterator(api.project('b').changes());
    addTearDown(beta.cancel);

    // Touch a doc in beta until its change arrives (the socket connects
    // asynchronously).
    final probe = File(p.join(dir.path, 'beta', 'backlog', 'docs', 'probe.md'));
    final pending = beta.moveNext();
    for (var attempt = 0; ; attempt++) {
      probe.writeAsStringSync('$attempt');
      final arrived = await Future.any([
        pending.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 200), () => false),
      ]);
      if (arrived) break;
      expect(attempt, lessThan(50), reason: 'no change event within 10 s');
    }
    expect(beta.current.paths, ['docs/probe.md']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(alphaEvents, isEmpty);
  });

  test('projects added to or removed from the registry start and stop without a restart', () async {
    final gamma = await backlogAt('gamma', 'G');
    File(registry).writeAsStringSync('''
# test registry
projects:
  - id: b
    name: Beta
    path: ../beta/backlog
  - path: $gamma
''');
    await eventually(() async => expect((await api.projects()).map((project) => project.id), ['b', 'gamma']));
    await api.project('gamma').createItem(const NewItemRequest(title: 'In gamma'));
    expect((await api.project('gamma').items()).single.title, 'In gamma');
    expect(() => api.project('alpha').items(), throwsA(apiError(404, 'not_found')));
    final fallback = HttpBacklogApi(server.uri, token: 'secret');
    addTearDown(fallback.close);
    expect((await fallback.workflow()).statuses, isNotEmpty);
    expect(await fallback.items(), isEmpty); // beta is the default now
    expect(logs, contains('Projects: b (default), gamma'));

    File(registry).writeAsStringSync('projects: [{path: a}, {path: b/a}]');
    await eventually(() => expect(logs.last, contains('not applied')));
    expect((await api.projects()).map((project) => project.id), ['b', 'gamma']);
  });

  test('a fixed backlog comes back once its configuration is repaired', () async {
    await expectLater(() => api.project('broken').items(), throwsA(apiError(500, 'configuration')));
    final config = File(p.join(dir.path, 'broken', 'backlog', 'backlog.yaml'));
    config.writeAsStringSync(File(p.join(dir.path, 'alpha', 'backlog', 'backlog.yaml')).readAsStringSync());
    await eventually(() async => expect(await api.project('broken').items(), isEmpty));
    expect((await api.projects())[2].isAvailable, isTrue);
  });
}
