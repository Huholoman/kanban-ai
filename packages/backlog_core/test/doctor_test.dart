import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> _git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
}

DoctorFinding _finding(List<DoctorSection> sections, String section, String subject) =>
    sections.firstWhere((s) => s.title == section).findings.firstWhere((f) => f.subject == subject);

void main() {
  late Directory dir;
  String path(String name) => p.join(dir.path, name);

  setUp(() async => dir = await Directory.systemTemp.createTemp('doctor_'));
  tearDown(() => dir.delete(recursive: true));

  test('tools, server, projects and dispatcher worktrees', () async {
    // A tool on the PATH, installed from a recorded ref.
    Directory(path('state/release/bin')).createSync(recursive: true);
    File(path('state/release/bin/backlog')).writeAsStringSync('');
    File(path('state/release.txt')).writeAsStringSync('main (0123456789ab) of /src/kanban-ai\n');
    Directory(path('bin')).createSync();
    Link(path('bin/backlog')).createSync(path('state/release/bin/backlog'));

    // A server answering on the configured port.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) => request.response.close());
    File(path('server.yaml')).writeAsStringSync('host: 127.0.0.1\nport: ${server.port}\n');

    // A primary clone with one created worktree (dirty), a project using it,
    // a listed worktree that is missing and a project whose folder is gone.
    Directory(path('repo')).createSync();
    await _git(path('repo'), ['init', '-q', '-b', 'main']);
    await _git(path('repo'), ['config', 'user.email', 'test@example.com']);
    await _git(path('repo'), ['config', 'user.name', 'Test']);
    File(path('repo/README')).writeAsStringSync('x\n');
    await _git(path('repo'), ['add', '.']);
    await _git(path('repo'), ['commit', '-q', '-m', 'Initial commit']);
    await _git(path('repo'), ['worktree', 'add', '-q', '--detach', path('repo-2'), 'main']);
    File(path('repo-2/notes')).writeAsStringSync('work\n');
    await Backlog.init(path('backlog'));
    final config = File(path('backlog/backlog.yaml'));
    config.writeAsStringSync(
      '${config.readAsStringSync()}\ndispatcher:\n  repo: ../repo\n  max_worktrees: 3\n  worktrees: [{name: gone, path: ../gone}]\n',
    );
    File(path('projects.yaml')).writeAsStringSync('projects:\n  - id: main\n    path: backlog\n  - path: missing\n');

    final sections = await runDoctor(
      environment: {'PATH': path('bin'), 'HOME': dir.path, 'KANBAN_AI_STATE_DIR': path('state')},
      registryFile: path('projects.yaml'),
      serverFile: path('server.yaml'),
    );
    expect(sections.map((s) => s.title), ['Tools', 'Server', 'Projects', 'Dispatcher worktrees']);

    final tool = _finding(sections, 'Tools', 'backlog');
    expect(tool.level, DoctorLevel.ok);
    expect(tool.detail, contains('from main (0123456789ab) of /src/kanban-ai'));
    expect(_finding(sections, 'Tools', 'backlog-server').level, DoctorLevel.warning);
    expect(_finding(sections, 'Tools', 'backlog-dev').level, DoctorLevel.info);

    expect(_finding(sections, 'Server', 'port ${server.port}').detail, contains('a server answers'));

    expect(_finding(sections, 'Projects', 'main').level, DoctorLevel.ok);
    expect(_finding(sections, 'Projects', 'missing').detail, contains('does not exist'));
    expect(sections[2].level, DoctorLevel.error);

    expect(_finding(sections, 'Dispatcher worktrees', 'main: gone').level, DoctorLevel.error);
    final created = _finding(sections, 'Dispatcher worktrees', 'main: repo-2');
    expect(created.level, DoctorLevel.warning);
    expect(created.detail, contains('1 changed file,'));

    File(path('repo-2/notes')).deleteSync();
    final again = await runDoctor(environment: {'PATH': ''}, registryFile: path('projects.yaml'));
    expect(_finding(again, 'Dispatcher worktrees', 'main: repo-2').level, DoctorLevel.ok);
    expect(_finding(again, 'Server', 'settings').detail, contains('no location'));
  });
}
