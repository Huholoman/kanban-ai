import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../backlog.dart';
import '../../dispatch/infrastructure/process_agent_launcher.dart';
import '../../projects/domain/project_registry.dart';
import '../../projects/infrastructure/yaml_project_registry.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/doctor.dart';
import '../domain/server_config.dart';
import 'file_config.dart';

/// The programs the doctor looks for on the `PATH`.
const doctorTools = ['backlog', 'backlog-server', 'backlog-dev', 'backlog-server-dev'];

/// Looks at this machine: [doctorTools] on the `PATH` and where they were
/// installed from (`release.txt`/`dev.txt`, written by `tool/install.sh`
/// next to the links in the state folder), whether a server answers on the
/// port of the server settings [serverFile] (and `$BACKLOG_PORT`), whether
/// the registry [registryFile] parses and each of its projects opens, and
/// whether the worktrees of their dispatchers exist and are clean.
Future<List<DoctorSection>> runDoctor({
  required Map<String, String> environment,
  String? registryFile,
  String? serverFile,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final home = environment['HOME'];
  final registry = await _registry(registryFile, home);
  return [
    _tools(environment),
    await _server(serverFile, environment, home, timeout),
    registry.$1,
    await _worktrees(registry.$2),
  ];
}

DoctorSection _tools(Map<String, String> environment) {
  final stateDir = ProcessAgentLauncher.defaultStateDir(environment);
  final folders = (environment['PATH'] ?? '').split(':').where((folder) => folder.isNotEmpty);
  final findings = <DoctorFinding>[
    DoctorFinding(
      DoctorLevel.info,
      'this program',
      '${Platform.resolvedExecutable} (Dart ${Platform.version.split(' ').first})',
    ),
  ];
  for (final tool in doctorTools) {
    String? found;
    for (final folder in folders) {
      final candidate = p.join(folder, tool);
      if (File(candidate).existsSync()) {
        found = candidate;
        break;
      }
    }
    final dev = tool.endsWith('-dev');
    if (found == null) {
      findings.add(
        DoctorFinding(
          dev ? DoctorLevel.info : DoctorLevel.warning,
          tool,
          'not on the PATH${dev ? '' : ' (mise run install)'}',
        ),
      );
      continue;
    }
    final target = _resolve(found);
    final info = File(p.join(stateDir, dev ? 'dev.txt' : 'release.txt'));
    final from = info.existsSync() ? info.readAsStringSync().trim() : null;
    findings.add(
      DoctorFinding(
        DoctorLevel.ok,
        tool,
        [
          found,
          if (target != found) '→ $target',
          if (from != null && target.startsWith(_resolve(p.join(stateDir, dev ? 'dev' : 'release')))) 'from $from',
        ].join('  '),
      ),
    );
  }
  return DoctorSection('Tools', findings);
}

String _resolve(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

Future<DoctorSection> _server(
  String? serverFile,
  Map<String, String> environment,
  String? home,
  Duration timeout,
) async {
  final findings = <DoctorFinding>[];
  var settings = ServerConfig.empty;
  if (serverFile == null) {
    findings.add(const DoctorFinding(DoctorLevel.info, 'settings', 'no location (HOME is not set)'));
  } else if (!File(serverFile).existsSync()) {
    findings.add(DoctorFinding(DoctorLevel.info, 'settings', '$serverFile does not exist: the defaults apply'));
  } else {
    try {
      settings = await loadServerConfig(serverFile, home: home);
      findings.add(DoctorFinding(DoctorLevel.ok, 'settings', serverFile));
    } on BacklogException catch (e) {
      findings.add(DoctorFinding(DoctorLevel.error, 'settings', e.message));
    }
  }
  final hosts = settings.hosts ?? const ['0.0.0.0'];
  final host = hosts.contains('0.0.0.0') || hosts.contains('::') ? '127.0.0.1' : hosts.first;
  final ports = {settings.port ?? 8640, ?int.tryParse(environment['BACKLOG_PORT'] ?? '')};
  for (final port in ports) {
    final url = Uri(scheme: 'http', host: host, port: port, path: '/api/health');
    final answer = await _get(url, timeout);
    findings.add(
      answer == null
          ? DoctorFinding(DoctorLevel.warning, 'port $port', 'no server answers at $url')
          : DoctorFinding(DoctorLevel.ok, 'port $port', 'a server answers at http://$host:$port ($answer)'),
    );
  }
  return DoctorSection('Server', findings);
}

/// The status line of a GET of [url], null when nothing answers in time.
Future<String?> _get(Uri url, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    return 'HTTP ${response.statusCode}';
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<(DoctorSection, List<(ProjectEntry, Backlog)>)> _registry(String? file, String? home) async {
  final opened = <(ProjectEntry, Backlog)>[];
  if (file == null) {
    return (const DoctorSection('Projects', [DoctorFinding(DoctorLevel.info, 'registry', 'no location')]), opened);
  }
  if (!File(file).existsSync()) {
    return (
      DoctorSection('Projects', [
        DoctorFinding(DoctorLevel.info, 'registry', '$file does not exist: no projects registered'),
      ]),
      opened,
    );
  }
  final ProjectRegistry registry;
  try {
    registry = await YamlProjectRegistryStore(file, home: home).load();
  } on BacklogException catch (e) {
    return (DoctorSection('Projects', [DoctorFinding(DoctorLevel.error, 'registry', e.message)]), opened);
  }
  final findings = [DoctorFinding(DoctorLevel.ok, 'registry', '$file (${registry.entries.length} projects)')];
  for (final entry in registry.entries) {
    if (!Directory(entry.path).existsSync()) {
      findings.add(DoctorFinding(DoctorLevel.error, entry.id, 'folder ${entry.path} does not exist'));
      continue;
    }
    try {
      final backlog = await Backlog.open(entry.path);
      opened.add((entry, backlog));
      findings.add(DoctorFinding(DoctorLevel.ok, entry.id, '${entry.path} opens'));
    } on BacklogException catch (e) {
      findings.add(DoctorFinding(DoctorLevel.error, entry.id, e.message));
    }
  }
  return (DoctorSection('Projects', findings), opened);
}

Future<DoctorSection> _worktrees(List<(ProjectEntry, Backlog)> projects) async {
  final findings = <DoctorFinding>[];
  for (final (entry, backlog) in projects) {
    final dispatcher = backlog.workflow.dispatcher;
    if (dispatcher == null) continue;
    final worktrees = [
      for (final worktree in dispatcher.worktrees) (worktree.name, worktree.resolvePath(backlog.root), true),
      ...await _created(dispatcher.newWorktrees, backlog.root),
    ];
    if (worktrees.isEmpty) {
      findings.add(DoctorFinding(DoctorLevel.info, entry.id, 'no worktrees yet (the dispatcher creates them)'));
    }
    for (final (name, path, listed) in worktrees) {
      findings.add(await _worktree('${entry.id}: $name', path, listed: listed));
    }
  }
  if (findings.isEmpty) findings.add(const DoctorFinding(DoctorLevel.info, 'dispatcher', 'no project has one'));
  return DoctorSection('Dispatcher worktrees', findings);
}

/// The worktrees of the primary clone named like [created] ones would be.
Future<List<(String, String, bool)>> _created(NewWorktrees? created, String root) async {
  if (created == null) return const [];
  final repo = created.resolveRepo(root);
  final pattern = RegExp(
    '^${created.name.text.split('{n}').map((part) => RegExp.escape(part.replaceAll('{repo}', p.basename(repo)))).join(r'\d+')}\$',
  );
  final ProcessResult result;
  try {
    result = await Process.run('git', ['worktree', 'list', '--porcelain'], workingDirectory: repo);
  } on ProcessException {
    return const [];
  }
  if (result.exitCode != 0) return const [];
  return [
    for (final line in '${result.stdout}'.split('\n'))
      if (line.startsWith('worktree ') && pattern.hasMatch(p.basename(line.substring(9))))
        (p.basename(line.substring(9)), line.substring(9), false),
  ];
}

Future<DoctorFinding> _worktree(String subject, String path, {required bool listed}) async {
  if (!Directory(path).existsSync()) {
    return DoctorFinding(
      listed ? DoctorLevel.error : DoctorLevel.warning,
      subject,
      '$path does not exist${listed ? '' : ' (git worktree prune removes the record)'}',
    );
  }
  try {
    final status = await Process.run('git', ['status', '--porcelain', '--branch'], workingDirectory: path);
    if (status.exitCode != 0) return DoctorFinding(DoctorLevel.error, subject, '$path is not a git worktree');
    final lines = '${status.stdout}'.split('\n').where((line) => line.isNotEmpty).toList();
    final branch = lines.isNotEmpty && lines.first.startsWith('## ') ? lines.first.substring(3) : '?';
    final changed = lines.where((line) => !line.startsWith('## ')).length;
    return changed == 0
        ? DoctorFinding(DoctorLevel.ok, subject, '$path clean, on $branch')
        : DoctorFinding(
            DoctorLevel.warning,
            subject,
            '$path has $changed changed ${changed == 1 ? 'file' : 'files'}, on $branch',
          );
  } on ProcessException catch (e) {
    return DoctorFinding(DoctorLevel.error, subject, 'git does not run: ${e.message}');
  }
}
