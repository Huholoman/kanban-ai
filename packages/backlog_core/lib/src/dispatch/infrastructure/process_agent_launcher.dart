import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../backlog.dart';
import '../../items/application/field_change.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/agent_session.dart';
import '../domain/dispatch_plan.dart';

/// Starts agents as detached processes that outlive the server, and looks
/// after them while they run.
///
/// **Launch:** the worktree must be a clean git worktree; the item is
/// claimed under the worktree's name (a conflict means someone was faster
/// and nothing starts), the worktree is switched to the assignment's branch
/// (created from `dispatcher.base` when missing; recorded in the item's
/// `branch` field) and the command runs in its own session with its output
/// appended to `logs/<project>/<id>-<time>.log`. The process is described by
/// `agents/<project>/<id>.json` (both under [stateDir]), which is how a
/// restarted server finds it again.
///
/// **While it runs** (checked every [pollInterval] once [attach]ed) its claim
/// gets a heartbeat every [heartbeatEvery] (default a quarter of the lease,
/// 1–10 minutes).
///
/// **When it ended:** an item still in the first active status and claimed
/// by the worktree is released (back to the pickable status) and *held*, so
/// that the dispatcher does not start it again by itself — unless it waits
/// for a person to answer its question ([PlannedItem.needsHuman]), which
/// keeps it from starting until the answer; an item the agent
/// handed over (e.g. `review`) keeps its status and loses only the claim.
/// The outcome is logged, appended to the log and kept in
/// `agents/<project>/<id>.last.json`, with the agent's session id, which a
/// later start of the item continues ([DispatchConditions.sessions]).
final class ProcessAgentLauncher extends AgentLauncher {
  ProcessAgentLauncher({
    required this.project,
    required Future<Backlog> Function() backlog,
    required this.stateDir,
    Clock clock = const SystemClock(),
    void Function(String message)? log,
    this.pollInterval = const Duration(seconds: 5),
    this.heartbeatEvery,
    Map<String, String>? environment,
  }) : _backlog = backlog,
       _clock = clock,
       _log = log ?? ((_) {}),
       _environment = environment ?? Platform.environment;

  /// `$KANBAN_AI_STATE_DIR`, else `$XDG_STATE_HOME/kanban-ai`, else
  /// `~/.local/state/kanban-ai`.
  static String defaultStateDir(Map<String, String> environment) {
    final explicit = environment['KANBAN_AI_STATE_DIR'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final xdg = environment['XDG_STATE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'kanban-ai');
    return p.join(environment['HOME'] ?? '.', '.local', 'state', 'kanban-ai');
  }

  /// Project id: separates the state of several backlogs.
  final String project;
  final String stateDir;
  final Duration pollInterval;
  final Duration? heartbeatEvery;
  final Future<Backlog> Function() _backlog;
  final Clock _clock;
  final void Function(String message) _log;
  final Map<String, String> _environment;
  final _lastHeartbeat = <ItemId, DateTime>{};
  Future<void> _queue = Future.value();
  Timer? _timer;
  void Function()? _onChange;
  bool _closed = false;

  String get agentsDir => p.join(stateDir, 'agents', project);
  String get logsDir => p.join(stateDir, 'logs', project);

  /// Runs the command, appends its output to the log, then records the exit
  /// code (atomically) and a closing line. Arguments: log, exit file, command.
  static const _wrapper =
      r'log=$1; exit_file=$2; shift 2; '
      r'"$@" </dev/null >>"$log" 2>&1; code=$?; '
      r'printf "%s\n" "$code" >"$exit_file.tmp" && mv "$exit_file.tmp" "$exit_file"; '
      r'printf "\n# kanban-ai: the agent exited with code %s at %s\n" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"; '
      r'exit "$code"';

  @override
  void attach(void Function() onChange) {
    _onChange = onChange;
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _queue;
  }

  @override
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async {
    final runs = await _records();
    final claimed = {
      for (final planned in snapshot.items)
        if (planned.isClaimed) planned.claim!.agent,
    };
    final unavailable = <String, String>{};
    for (final worktree in config.worktrees) {
      if (claimed.contains(worktree.name) || runs.any((r) => r.run.worktree == worktree.name)) continue;
      final problem = await worktreeProblem(worktree.resolvePath(backlogRoot));
      if (problem != null) unavailable[worktree.name] = problem;
    }
    final held = <ItemId, String>{};
    for (final id in await _heldIds()) {
      final planned = snapshot[id];
      if (planned == null || planned.isDone) continue;
      if (await _holdOf(id) case final reason?) held[id] = reason;
    }
    return DispatchConditions(
      unavailable: unavailable,
      held: held,
      runs: [for (final record in runs) record.run],
      sessions: await _sessions(snapshot),
    );
  }

  /// The sessions of the last runs (`<id>.last.json`) of items that are
  /// still open or in progress.
  Future<Map<ItemId, AgentSession>> _sessions(BacklogSnapshot snapshot) async {
    final dir = Directory(agentsDir);
    if (!await dir.exists()) return const {};
    const suffix = '.last.json';
    final sessions = <ItemId, AgentSession>{};
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      if (entry is! File || !name.endsWith(suffix)) continue;
      final id = ItemId(name.substring(0, name.length - suffix.length));
      final planned = snapshot[id];
      if (planned == null || planned.isDone) continue;
      try {
        final json = (jsonDecode(await entry.readAsString()) as Map).cast<String, Object?>();
        if (json['session_id'] case final String session when session.isNotEmpty) {
          sessions[id] = AgentSession(
            item: id,
            id: session,
            worktree: json['worktree']! as String,
            agent: json['agent'] as String? ?? '?',
            startedAt: DateTime.parse(json['started_at']! as String),
            endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
            reason: json['reason'] as String?,
            outcome: json['outcome'] as String?,
          );
        }
      } on Object catch (error) {
        _log('Dispatcher: ignoring unreadable ${entry.path}: $error');
      }
    }
    return sessions;
  }

  /// Why an agent cannot start in the worktree at [path]; null when it is a
  /// git worktree without uncommitted changes or untracked files.
  static Future<String?> worktreeProblem(String path) async {
    if (!await Directory(path).exists()) return 'folder $path does not exist';
    final ProcessResult status;
    try {
      status = await Process.run('git', ['status', '--porcelain'], workingDirectory: path);
    } on ProcessException catch (error) {
      return 'git cannot run: ${error.message}';
    }
    if (status.exitCode != 0) return 'not a git worktree (${_firstLine(status.stderr)})';
    final changes = LineSplitter.split('${status.stdout}').where((line) => line.trim().isNotEmpty).length;
    return changes == 0 ? null : 'uncommitted changes ($changes paths)';
  }

  @override
  Future<void> launch(DispatchAssignment assignment) => _serialized(() async {
    final id = assignment.id;
    if (await _record(id) != null) throw UnavailableException('An agent already runs for $id.');
    final problem = await worktreeProblem(assignment.path);
    if (problem != null) {
      _log('Dispatcher: not starting $id in ${assignment.agent}: $problem.');
      throw UnavailableException('Worktree ${assignment.agent}: $problem.');
    }
    final backlog = await _backlog();
    await backlog.claims.claim(id.value, assignment.agent);
    final _Record record;
    try {
      final branch = assignment.branch;
      if (branch != null) {
        await _checkout(assignment, branch, assignment.base ?? 'main');
        if (assignment.item.item.branch != branch) {
          await backlog.items.update(id.value, [FieldChange.parse('branch=$branch')]);
        }
      }
      record = await _spawn(assignment);
    } catch (_) {
      await backlog.claims.release(id.value, agent: assignment.agent);
      rethrow;
    }
    await _delete(_holdFile(id));
    _lastHeartbeat[id] = _clock.now();
    _log(
      'Dispatcher: started ${assignment.agentProfile.name} for $id in ${assignment.agent} '
      '(pid ${record.run.pid}, branch ${assignment.branch ?? '-'}'
      '${assignment.resume == null ? '' : ', resuming session ${assignment.resume!.id}'}, log ${record.run.log}).',
    );
    _onChange?.call();
  });

  @override
  Future<bool> stop(ItemId item) async {
    final record = await _record(item);
    if (record == null) return false;
    await File(_stopFile(item)).writeAsString('${_clock.now().toUtc().toIso8601String()}\n');
    await _signal(record, ProcessSignal.sigterm);
    for (var i = 0; i < 50 && await _alive(record); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await _alive(record)) await _signal(record, ProcessSignal.sigkill);
    await tick();
    return true;
  }

  /// Heartbeats the claims of running agents and finishes the ended ones.
  Future<void> tick() => _serialized(() async {
    if (_closed) return;
    var changed = false;
    for (final record in await _records()) {
      try {
        if (await _alive(record)) {
          await _heartbeat(record);
        } else {
          await _finish(record);
          changed = true;
        }
      } catch (error) {
        _log('Dispatcher: looking after the agent for ${record.run.item} failed: $error');
      }
    }
    if (changed) _onChange?.call();
  });

  @override
  Future<AgentLog?> agentLog(ItemId item, {int lines = 100}) async {
    final record = await _record(item);
    Map<String, Object?>? last;
    String? path = record?.run.log;
    if (path == null) {
      final file = File(_lastFile(item));
      if (!await file.exists()) return null;
      last = (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
      path = last['log'] as String?;
      if (path == null) return null;
    }
    final file = File(path);
    final all = await file.exists() ? await file.readAsLines() : const <String>[];
    return AgentLog(
      path: path,
      lines: all.length <= lines ? all : all.sublist(all.length - lines),
      running: record != null,
      last: last,
    );
  }

  // ---------------------------------------------------------------- launch

  Future<void> _checkout(DispatchAssignment assignment, String branch, String base) async {
    Future<ProcessResult> git(List<String> arguments) =>
        Process.run('git', arguments, workingDirectory: assignment.path);
    String fail(String what, ProcessResult result) =>
        throw UnavailableException('Worktree ${assignment.agent}: $what (${_firstLine(result.stderr)}).');

    final valid = await git(['check-ref-format', '--branch', branch]);
    if (valid.exitCode != 0) fail('"$branch" is not a valid branch name', valid);
    final head = await git(['symbolic-ref', '--quiet', '--short', 'HEAD']);
    if (head.exitCode == 0 && '${head.stdout}'.trim() == branch) return;
    final exists = await git(['rev-parse', '--verify', '--quiet', 'refs/heads/$branch']);
    final switched = exists.exitCode == 0
        ? await git(['switch', branch])
        : await git(['switch', '--no-track', '-c', branch, base]);
    if (switched.exitCode != 0) fail('cannot switch to branch $branch', switched);
  }

  Future<_Record> _spawn(DispatchAssignment assignment) async {
    final id = assignment.id;
    final now = _clock.now();
    await Directory(agentsDir).create(recursive: true);
    await Directory(logsDir).create(recursive: true);
    final log = p.join(logsDir, '$id-${_stamp(now)}.log');
    await _delete(_exitFile(id));
    await _delete(_stopFile(id));
    await File(log).writeAsString(
      '# kanban-ai: ${assignment.agentProfile.name} for $id in ${assignment.agent} (${assignment.path}), '
      'branch ${assignment.branch ?? '-'}, started ${now.toUtc().toIso8601String()}'
      '${assignment.resume == null ? '' : ', resuming session ${assignment.resume!.id}'}\n'
      '# command: ${CommandTemplate.join(assignment.command)}\n',
      mode: FileMode.append,
    );
    final process = await Process.start(
      'sh',
      ['-c', _wrapper, 'kanban-ai-agent', log, _exitFile(id), ...assignment.command],
      workingDirectory: assignment.path,
      environment: {..._environment, ...assignment.environment},
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
    final record = _Record(
      AgentRun(
        item: id,
        worktree: assignment.agent,
        pid: process.pid,
        startedAt: now,
        log: log,
        agent: assignment.agentProfile.name,
        branch: assignment.branch,
      ),
      path: assignment.path,
      pgid: await _processGroup(process.pid),
      output: assignment.agentProfile.output,
      resumed: assignment.resume?.id,
    );
    await _write(_recordFile(id), record.toJson());
    return record;
  }

  // ------------------------------------------------------------ supervise

  Future<void> _heartbeat(_Record record) async {
    final id = record.run.item;
    final now = _clock.now();
    final backlog = await _backlog();
    final every = heartbeatEvery ?? _clampDuration(backlog.workflow.claimLease ~/ 4);
    final last = _lastHeartbeat[id];
    if (last != null && now.difference(last) < every) return;
    _lastHeartbeat[id] = now;
    try {
      await backlog.claims.heartbeat(id.value, record.run.worktree);
    } on ClaimConflictException {
      // The agent finished or released it already; nothing to keep alive.
    }
  }

  Future<void> _finish(_Record record) async {
    final run = record.run;
    final id = run.item;
    final exitText = await _read(_exitFile(id));
    final exitCode = exitText == null ? null : int.tryParse(exitText.trim());
    final stopped = await File(_stopFile(id)).exists();
    final reason = stopped
        ? 'was stopped by a person'
        : exitCode == null
        ? 'ended without an exit code (killed?)'
        : 'exited with code $exitCode';

    final backlog = await _backlog();
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[id];
    final String outcome;
    if (planned == null) {
      outcome = 'the item is gone';
    } else if (planned.claim?.agent == run.worktree) {
      if (planned.item.status == backlog.workflow.activeStatus && planned.needsHuman) {
        // It asked a question: back to the queue, not ready until a person answers.
        await backlog.claims.release(id.value, agent: run.worktree, force: true);
        outcome = 'it asked a question; released, waits for a person to answer';
      } else if (planned.item.status == backlog.workflow.activeStatus) {
        await backlog.claims.release(id.value, agent: run.worktree, force: true);
        await _write(_holdFile(id), {
          'reason': 'The last agent ($reason) left it unfinished.',
          'at': _clock.now().toUtc().toIso8601String(),
        });
        outcome = 'it left ${planned.item.status}, released and held (start it again by hand)';
      } else {
        await backlog.claims.drop(id.value, run.worktree);
        outcome = 'it handed over as ${planned.item.status}, claim dropped';
      }
    } else {
      outcome =
          'the item is ${planned.item.status}${planned.claim == null ? '' : ', claimed by ${planned.claim!.agent}'}';
    }
    final session = record.output == AgentOutput.claudeStreamJson
        ? await _claudeSession(run.log) ?? record.resumed
        : record.resumed;
    final ended = _clock.now();
    await _write(_lastFile(id), {
      ...record.toJson(),
      'ended_at': ended.toUtc().toIso8601String(),
      'exit_code': exitCode,
      'reason': reason,
      'outcome': outcome,
      'session_id': session,
    });
    try {
      await File(run.log).writeAsString(
        '# kanban-ai: the agent $reason; $outcome'
        '${session == null ? '' : '; resume with: cd ${record.path} && claude --resume $session'}\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // The log was removed; the outcome is still in the server log.
    }
    for (final file in [_recordFile(id), _exitFile(id), _stopFile(id)]) {
      await _delete(file);
    }
    _lastHeartbeat.remove(id);
    _log(
      'Dispatcher: the agent for $id in ${run.worktree} $reason; $outcome'
      '${session == null ? '' : '; resume: cd ${record.path} && claude --resume $session'}.',
    );
  }

  static Future<String?> _claudeSession(String log) async {
    final file = File(log);
    if (!await file.exists()) return null;
    String? session;
    for (final line in await file.readAsLines()) {
      if (!line.startsWith('{') || !line.contains('"session_id"')) continue;
      try {
        final json = jsonDecode(line);
        if (json is Map && json['session_id'] is String) session = json['session_id'] as String;
      } on FormatException {
        continue;
      }
    }
    return session;
  }

  // --------------------------------------------------------------- process

  Future<bool> _alive(_Record record) async {
    if (await File(_exitFile(record.run.item)).exists()) return false;
    final pid = record.run.pid;
    final proc = File('/proc/$pid/cmdline');
    if (await Directory('/proc').exists()) {
      try {
        return (await proc.readAsString()).contains(record.run.log);
      } on FileSystemException {
        return false;
      }
    }
    return (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
  }

  static Future<int?> _processGroup(int pid) async {
    try {
      final stat = await File('/proc/$pid/stat').readAsString();
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return int.tryParse(fields[2]); // state, ppid, pgrp
    } on FileSystemException {
      final ps = await Process.run('ps', ['-o', 'pgid=', '-p', '$pid']);
      return int.tryParse('${ps.stdout}'.trim());
    }
  }

  static Future<void> _signal(_Record record, ProcessSignal signal) async {
    final group = record.pgid;
    if (group != null && group > 1) {
      final name = signal == ProcessSignal.sigkill ? '-KILL' : '-TERM';
      final result = await Process.run('kill', [name, '--', '-$group']);
      if (result.exitCode == 0) return;
    }
    Process.killPid(record.run.pid, signal);
  }

  // ----------------------------------------------------------------- files

  String _recordFile(ItemId id) => p.join(agentsDir, '$id.json');
  String _exitFile(ItemId id) => p.join(agentsDir, '$id.exit');
  String _stopFile(ItemId id) => p.join(agentsDir, '$id.stop');
  String _holdFile(ItemId id) => p.join(agentsDir, '$id.hold.json');
  String _lastFile(ItemId id) => p.join(agentsDir, '$id.last.json');

  Future<_Record?> _record(ItemId id) async {
    final text = await _read(_recordFile(id));
    return text == null ? null : _Record.fromJson(jsonDecode(text) as Map<String, Object?>);
  }

  Future<List<_Record>> _records() async {
    final dir = Directory(agentsDir);
    if (!await dir.exists()) return const [];
    final records = <_Record>[];
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      if (entry is! File || !name.endsWith('.json') || name.endsWith('.hold.json') || name.endsWith('.last.json')) {
        continue;
      }
      try {
        records.add(_Record.fromJson(jsonDecode(await entry.readAsString()) as Map<String, Object?>));
      } on Object catch (error) {
        _log('Dispatcher: ignoring unreadable ${entry.path}: $error');
      }
    }
    return records..sort((a, b) => a.run.item.value.compareTo(b.run.item.value));
  }

  Future<List<ItemId>> _heldIds() async {
    final dir = Directory(agentsDir);
    if (!await dir.exists()) return const [];
    const suffix = '.hold.json';
    return [
      await for (final entry in dir.list())
        if (p.basename(entry.path) case final name when name.endsWith(suffix))
          ItemId(name.substring(0, name.length - suffix.length)),
    ];
  }

  Future<String?> _holdOf(ItemId id) async {
    final text = await _read(_holdFile(id));
    if (text == null) return null;
    try {
      return '${(jsonDecode(text) as Map)['reason']}';
    } on FormatException {
      return 'held';
    }
  }

  static Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static Future<void> _write(String path, Map<String, Object?> json) async {
    await Directory(p.dirname(path)).create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');
    await temp.rename(path);
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Duration _clampDuration(Duration value) => value < const Duration(minutes: 1)
      ? const Duration(minutes: 1)
      : value > const Duration(minutes: 10)
      ? const Duration(minutes: 10)
      : value;

  static String _stamp(DateTime time) {
    final utc = time.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static String _firstLine(Object? text) => '$text'.trim().split('\n').first;
}

/// What `agents/<project>/<id>.json` holds about a running agent.
final class _Record {
  _Record(this.run, {required this.path, required this.pgid, required this.output, this.resumed});

  factory _Record.fromJson(Map<String, Object?> json) => _Record(
    AgentRun(
      item: ItemId(json['item']! as String),
      worktree: json['worktree']! as String,
      pid: json['pid']! as int,
      startedAt: DateTime.parse(json['started_at']! as String),
      log: json['log']! as String,
      agent: json['agent'] as String? ?? '?',
      branch: json['branch'] as String?,
    ),
    path: json['path']! as String,
    pgid: json['pgid'] as int?,
    output: AgentOutput.values.firstWhere((o) => o.id == json['output'], orElse: () => AgentOutput.text),
    resumed: json['resumed'] as String?,
  );

  final AgentRun run;

  /// Absolute path of the worktree.
  final String path;

  /// Process group of the agent (its own session); signalled by `stop`.
  final int? pgid;
  final AgentOutput output;

  /// The session this run continues; null for a new one.
  final String? resumed;

  Map<String, Object?> toJson() => {
    'item': run.item.value,
    'worktree': run.worktree,
    'path': path,
    'pid': run.pid,
    'pgid': pgid,
    'started_at': run.startedAt.toUtc().toIso8601String(),
    'log': run.log,
    'agent': run.agent,
    'output': output.id,
    'branch': run.branch,
    'resumed': resumed,
  };
}
