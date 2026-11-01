import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/action_run.dart';
import '../domain/agent_log_format.dart';
import '../domain/dispatch_plan.dart';
import 'process_agent_launcher.dart';

/// Adds worktrees on demand (`dispatcher.repo`) in front of another
/// [AgentLauncher], which starts and watches the agents as before.
///
/// **Which worktrees:** the listed ones (`dispatcher.worktrees`) plus those
/// this provisioner created earlier, recorded in
/// `worktrees/<project>/<name>.json` under [stateDir] (a record whose folder
/// is gone is dropped). Folders the dispatcher did not create are never
/// adopted, even when their names fit the pattern.
///
/// **New ones:** while `max_worktrees` allows, the plan gets the next names
/// of `dispatcher.worktree_name` as spare worktrees: the first numbers from
/// 2 on whose name is neither listed, nor recorded, nor held by a live
/// claim, and whose folder (next to the primary clone) does not exist. An
/// assignment to a spare worktree first runs
/// `git worktree add --detach <path> <base>` in the primary clone, so the new worktree has nothing
/// uncommitted, then the `dispatcher.setup` commands in it (output in
/// `logs/<project>/worktree-<name>-<time>.log`); when one fails, the
/// worktree is removed again and the start fails with the reason. The
/// agent's branch is then prepared by the inner launcher.
///
/// **Cleanup** (only with `cleanup_after_days`): a created worktree that is
/// free, has been idle that long, has no uncommitted changes or untracked
/// files and whose checked-out commit is contained in `dispatcher.base`
/// (merged, or no commits of its own) is removed with `git worktree remove`
/// (never forced); its branch stays. A worktree is kept, however idle, while
/// it holds the last agent session of an unfinished item
/// ([DispatchConditions.sessions]): a later start, a person's reply or an
/// open question of that agent continues the session there, and only there.
/// Names of such worktrees are not reused for new ones either.
final class WorktreeProvisioner extends AgentLauncher {
  WorktreeProvisioner(
    this._inner, {
    required this.project,
    required this.stateDir,
    Clock clock = const SystemClock(),
    void Function(String message)? log,
  }) : _clock = clock,
       _log = log ?? ((_) {});

  final AgentLauncher _inner;

  /// Project id: separates the state of several backlogs.
  final String project;
  final String stateDir;
  final Clock _clock;
  final void Function(String message) _log;

  /// How often "last used" of a busy worktree is written at most.
  static const _touchEvery = Duration(minutes: 10);

  String get recordsDir => p.join(stateDir, 'worktrees', project);

  @override
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async {
    final added = config.newWorktrees;
    if (added == null) return _inner.conditions(config, backlogRoot, snapshot);

    final listed = {for (final worktree in config.worktrees) worktree.name};
    var records = [
      for (final record in await _records(backlogRoot))
        if (!listed.contains(record.name)) record,
    ];
    var created = [for (final record in records) WorktreeDefinition(record.name, record.path)];
    final inner = await _inner.conditions(
      config.withWorktrees([...config.worktrees, ...created]),
      backlogRoot,
      snapshot,
    );

    final claimed = {
      for (final planned in snapshot.items)
        if (planned.isClaimed) planned.claim!.agent,
    };
    bool busy(String name) => claimed.contains(name) || inner.runs.any((run) => run.worktree == name);
    // Worktrees an unfinished item's agent session lives in: kept for resuming.
    final sessionHomes = {
      for (final MapEntry(:key, :value) in inner.sessions.entries)
        if (snapshot[key] case final planned? when !planned.isDone) value.worktree,
    };

    final now = _clock.now();
    final removed = <String>{};
    for (final record in records) {
      if (busy(record.name)) {
        if (now.difference(record.lastUsed) >= _touchEvery) await _write(record.copyWith(lastUsed: now));
      } else if (added.cleanupAfter case final after?
          when inner.unavailable[record.name] == null &&
              !sessionHomes.contains(record.name) &&
              now.difference(record.lastUsed) >= after) {
        if (await _cleanUp(record, config.base)) removed.add(record.name);
      }
    }
    if (removed.isNotEmpty) {
      records = [
        for (final record in records)
          if (!removed.contains(record.name)) record,
      ];
      created = [for (final record in records) WorktreeDefinition(record.name, record.path)];
    }

    final taken = {...listed, for (final record in records) record.name, ...claimed, ...sessionHomes};
    final spare = <WorktreeDefinition>[];
    final room = added.maxWorktrees - config.worktrees.length - records.length;
    for (var n = 2; spare.length < room && n < 2 + room + 1000; n++) {
      final worktree = added.worktree(added.nameFor(n), backlogRoot);
      if (taken.contains(worktree.name) ||
          await FileSystemEntity.type(worktree.path) != FileSystemEntityType.notFound) {
        continue;
      }
      spare.add(worktree);
    }
    return DispatchConditions(
      unavailable: {
        for (final MapEntry(:key, :value) in inner.unavailable.entries)
          if (!removed.contains(key)) key: value,
      },
      held: inner.held,
      blocked: inner.blocked,
      runs: inner.runs,
      sessions: inner.sessions,
      starts: inner.starts,
      created: created,
      spare: spare,
      branches: inner.branches,
      problems: inner.problems,
    );
  }

  @override
  Future<void> launch(DispatchAssignment assignment) async {
    final repo = assignment.createFrom;
    if (repo != null) await _create(assignment, repo);
    await _inner.launch(assignment);
    if (await _record(assignment.worktree.name) case final record?) {
      await _write(record.copyWith(lastUsed: _clock.now()));
    }
  }

  @override
  Future<void> runJob(ActionJob job) => _inner.runJob(job);

  Future<void> _create(DispatchAssignment assignment, String repo) async {
    final path = assignment.path;
    final name = assignment.worktree.name;
    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
      throw UnavailableException('Cannot create worktree $name: $path already exists.');
    }
    final base = assignment.base ?? 'main';
    final ProcessResult result;
    try {
      result = await Process.run('git', ['worktree', 'add', '--detach', path, base], workingDirectory: repo);
    } on ProcessException catch (error) {
      throw UnavailableException('Cannot create worktree $name: git cannot run in $repo (${error.message}).');
    }
    if (result.exitCode != 0) {
      throw UnavailableException(
        'Cannot create worktree $name from $repo: ${'${result.stderr}'.trim().split('\n').last}',
      );
    }
    final setup = assignment.setup;
    if (setup.isNotEmpty) {
      final failure = await _setUp(setup, name: name, path: path, repo: repo, base: base);
      if (failure != null) {
        final removed = await Process.run('git', ['worktree', 'remove', '--force', path], workingDirectory: repo);
        _log(
          'Dispatcher: setting up worktree $name failed: $failure; '
          '${removed.exitCode == 0 ? 'removed it again' : 'could not remove it: ${'${removed.stderr}'.trim()}'}.',
        );
        throw UnavailableException('Cannot use the new worktree $name: $failure.');
      }
    }
    final now = _clock.now();
    await _write(_WorktreeRecord(name: name, path: path, repo: repo, createdAt: now, lastUsed: now));
    _log('Dispatcher: created worktree $name at $path (from $repo, $base).');
  }

  /// How long one setup command may run.
  static const setupTimeout = Duration(minutes: 15);

  /// Runs the [setup] commands one after another in the new worktree at
  /// [path], their output in `logs/<project>/worktree-<name>-<time>.log`;
  /// returns what failed (with the log), null when all succeeded.
  Future<String?> _setUp(
    List<CommandTemplate> setup, {
    required String name,
    required String path,
    required String repo,
    required String base,
  }) async {
    final now = _clock.now().toUtc();
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[-:]|\.\d+'), '');
    final log = File(p.join(stateDir, 'logs', project, 'worktree-$name-$stamp.log'));
    await log.parent.create(recursive: true);
    final sink = log.openWrite();
    try {
      sink.writeln('# kanban-ai: setting up worktree $name ($path), ${now.toIso8601String()}');
      for (final template in setup) {
        final command = template.render({'worktree': name, 'path': path, 'repo': repo, 'base': base});
        final shown = CommandTemplate.join(command);
        sink.writeln('# command: $shown');
        final Process process;
        try {
          process = await Process.start(command.first, command.skip(1).toList(), workingDirectory: path);
        } on ProcessException catch (error) {
          sink.writeln('# kanban-ai: cannot run it: ${error.message}');
          return '`$shown` cannot run (${error.message}; log ${log.path})';
        }
        unawaited(process.stdin.close());
        final output = [
          process.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(sink.write),
          process.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(sink.write),
        ];
        final code = await process.exitCode.timeout(
          setupTimeout,
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        await Future.wait(output);
        if (code != 0) {
          final why = code == -1 ? 'took longer than ${setupTimeout.inMinutes} min' : 'exited with code $code';
          sink.writeln('# kanban-ai: $why');
          return '`$shown` $why (log ${log.path})';
        }
      }
      sink.writeln('# kanban-ai: worktree $name is set up');
      return null;
    } finally {
      await sink.close();
    }
  }

  /// Removes [record]'s worktree when nothing is lost; true when it is gone.
  Future<bool> _cleanUp(_WorktreeRecord record, String base) async {
    Future<ProcessResult> git(List<String> arguments, {String? inside}) =>
        Process.run('git', arguments, workingDirectory: inside ?? record.path);
    try {
      if (await ProcessAgentLauncher.worktreeProblem(record.path) != null) return false;
      final contained = await git(['merge-base', '--is-ancestor', 'HEAD', base]);
      if (contained.exitCode != 0) return false; // commits of its own that are not in the base
      final removed = await git(['worktree', 'remove', record.path], inside: record.repo);
      if (removed.exitCode != 0) {
        _log('Dispatcher: could not remove idle worktree ${record.name}: ${'${removed.stderr}'.trim()}');
        return false;
      }
    } on ProcessException catch (error) {
      _log('Dispatcher: could not remove idle worktree ${record.name}: ${error.message}');
      return false;
    }
    await _delete(_recordFile(record.name));
    _log('Dispatcher: removed idle worktree ${record.name} (${record.path}).');
    return true;
  }

  // ----------------------------------------------------------------- records

  String _recordFile(String name) => p.join(recordsDir, '$name.json');

  /// The recorded worktrees whose folders still exist, by name; the others'
  /// records are dropped.
  Future<List<_WorktreeRecord>> _records(String backlogRoot) async {
    final dir = Directory(recordsDir);
    if (!await dir.exists()) return const [];
    final records = <_WorktreeRecord>[];
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final _WorktreeRecord record;
      try {
        record = _WorktreeRecord.fromJson(jsonDecode(await entry.readAsString()) as Map<String, Object?>);
      } on Object catch (error) {
        _log('Dispatcher: ignoring unreadable ${entry.path}: $error');
        continue;
      }
      if (await Directory(record.path).exists()) {
        records.add(record);
      } else {
        _log('Dispatcher: worktree ${record.name} (${record.path}) is gone; forgetting it.');
        await _delete(entry.path);
      }
    }
    return records..sort((a, b) => _natural(a.name, b.name));
  }

  Future<_WorktreeRecord?> _record(String name) async {
    try {
      return _WorktreeRecord.fromJson(jsonDecode(await File(_recordFile(name)).readAsString()) as Map<String, Object?>);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _write(_WorktreeRecord record) async {
    final path = _recordFile(record.name);
    await Directory(p.dirname(path)).create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(record.toJson())}\n');
    await temp.rename(path);
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// `app-2` before `app-10`.
  static int _natural(String a, String b) {
    final digits = RegExp(r'\d+$');
    final (ma, mb) = (digits.firstMatch(a), digits.firstMatch(b));
    if (ma != null && mb != null && a.substring(0, ma.start) == b.substring(0, mb.start)) {
      return int.parse(ma[0]!).compareTo(int.parse(mb[0]!));
    }
    return a.compareTo(b);
  }

  // -------------------------------------------------------------- delegated

  @override
  Future<bool> stop(ItemId item) => _inner.stop(item);

  @override
  Future<AgentLog?> agentLog(ItemId item, {int lines = 100}) => _inner.agentLog(item, lines: lines);

  @override
  Future<AgentLogSource?> agentLogSource(ItemId item) => _inner.agentLogSource(item);

  @override
  void attach(void Function() onChange) => _inner.attach(onChange);

  @override
  Future<void> close() => _inner.close();
}

/// What `worktrees/<project>/<name>.json` holds about a worktree the
/// dispatcher created.
final class _WorktreeRecord {
  const _WorktreeRecord({
    required this.name,
    required this.path,
    required this.repo,
    required this.createdAt,
    required this.lastUsed,
  });

  factory _WorktreeRecord.fromJson(Map<String, Object?> json) => _WorktreeRecord(
    name: json['name']! as String,
    path: json['path']! as String,
    repo: json['repo']! as String,
    createdAt: DateTime.parse(json['created_at']! as String),
    lastUsed: DateTime.parse((json['last_used'] ?? json['created_at'])! as String),
  );

  final String name;

  /// Absolute path of the worktree.
  final String path;

  /// The primary clone it was added from.
  final String repo;
  final DateTime createdAt;

  /// When an agent last started or was seen running in it.
  final DateTime lastUsed;

  _WorktreeRecord copyWith({DateTime? lastUsed}) =>
      _WorktreeRecord(name: name, path: path, repo: repo, createdAt: createdAt, lastUsed: lastUsed ?? this.lastUsed);

  Map<String, Object?> toJson() => {
    'name': name,
    'path': path,
    'repo': repo,
    'created_at': createdAt.toUtc().toIso8601String(),
    'last_used': lastUsed.toUtc().toIso8601String(),
  };
}
