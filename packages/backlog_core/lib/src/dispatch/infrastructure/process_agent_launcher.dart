import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../../backlog.dart';
import '../../items/application/field_change.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/action_run.dart';
import '../domain/agent_log_format.dart';
import '../domain/agent_session.dart';
import '../domain/dispatch_plan.dart';
import 'built_in_actions.dart';
import 'merge_action.dart';
import 'pull_request_opener.dart';
import 'pull_request_watcher.dart';

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
/// **Branch in another worktree:** git checks a branch out in one worktree
/// only. When the assignment's branch is checked out elsewhere (e.g. where
/// a `fresh` review ran), that worktree is detached (`git switch --detach`)
/// if the dispatcher manages it (listed or created) and it is free (no live
/// claim, nothing runs there) and clean. Otherwise nothing starts: an
/// agent's item is *held* with the reason and a note in its discussion
/// (once); the hold also stops a person's reply from waking the agent
/// ([DispatchConditions.blocked]) and goes away by itself once the branch is
/// free or its worktree can be freed. A prompt action fails with
/// `InvalidInputException`, which the dispatcher notes once and drops.
/// Actions therefore need not give the branch back when they end.
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
/// handed over (e.g. `review`) keeps its status and loses only the claim;
/// with `dispatcher.pr` it also gets the pull request the agent did not
/// open ([PullRequestOpener]), noted in its discussion.
/// The outcome is logged, appended to the log and kept in
/// `agents/<project>/<id>.last.json`, with the agent's session id, which a
/// later start of the item continues ([DispatchConditions.sessions]), its
/// final message (`result`) and what went wrong (`problems`: a failed exit,
/// an error ending, denied tool calls, a pull request it could not open),
/// which make the item need a person ([DispatchConditions.problems]).
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
    Map<String, BuiltInAction>? builtIns,
  }) : _backlog = backlog,
       _clock = clock,
       _log = log ?? ((_) {}),
       _environment = environment ?? Platform.environment,
       _builtIns = builtIns ?? BuiltInActions.standard {
    _pullRequests = PullRequestWatcher(
      project: project,
      stateDir: stateDir,
      backlog: backlog,
      running: (item) async => await _record(item) != null,
      serialized: _serialized,
      clock: clock,
      environment: environment,
      log: _log,
    );
  }

  late final PullRequestWatcher _pullRequests;

  /// Who writes the launcher's notes in the discussion (results of actions).
  static const noteAuthor = 'kanban-ai';

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
  final Map<String, BuiltInAction> _builtIns;

  /// Worktrees the dispatcher manages (listed and created), name → path, as
  /// of the last [conditions].
  var _managed = <String, String>{};

  /// Built-in actions running inside this process, with their result once
  /// they ended.
  final _builtInRuns = <ItemId, BuiltInActionResult?>{};
  final _lastHeartbeat = <ItemId, DateTime>{};
  Future<void> _queue = Future.value();
  Timer? _timer;
  void Function()? _onChange;
  bool _closed = false;

  String get agentsDir => p.join(stateDir, 'agents', project);
  String get logsDir => p.join(stateDir, 'logs', project);

  /// Runs the command, appends its output to the log, then a closing line,
  /// and only then records the exit code (atomically): once the exit file is
  /// there the log is complete and the launcher's own lines come after it.
  /// Arguments: log, exit file, command.
  static const _wrapper =
      r'log=$1; exit_file=$2; shift 2; '
      r'"$@" </dev/null >>"$log" 2>&1; code=$?; '
      r'printf "\n# kanban-ai: the agent exited with code %s at %s\n" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"; '
      r'printf "%s\n" "$code" >"$exit_file.tmp" && mv "$exit_file.tmp" "$exit_file"; '
      r'exit "$code"';

  @override
  void attach(void Function() onChange) {
    _onChange = onChange;
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) {
      unawaited(tick());
      unawaited(pollPullRequests());
    });
    unawaited(tick());
  }

  /// Asks `dispatcher.pr.state` about the pull requests of active items
  /// (at most every `state_every`, unless [force]) and makes those merged
  /// outside the board done ([PullRequestWatcher]); returns them.
  Future<List<ItemId>> pollPullRequests({bool force = false}) async {
    if (_closed) return const [];
    final merged = await _pullRequests.poll(force: force);
    if (merged.isNotEmpty) _onChange?.call();
    return merged;
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
    _managed = {for (final worktree in config.worktrees) worktree.name: worktree.resolvePath(backlogRoot)};
    final unavailable = <String, String>{};
    final branches = <String, String>{};
    for (final worktree in config.worktrees) {
      if (claimed.contains(worktree.name) || runs.any((r) => r.run.worktree == worktree.name)) continue;
      final path = worktree.resolvePath(backlogRoot);
      final problem = await worktreeProblem(path);
      if (problem != null) unavailable[worktree.name] = problem;
      if (await worktreeBranch(path) case final branch?) branches[worktree.name] = branch;
    }
    final held = <ItemId, String>{};
    final blocked = <ItemId>{};
    final last = await _sessions(snapshot);
    for (final id in await _heldIds()) {
      final planned = snapshot[id];
      if (planned == null || planned.isDone) continue;
      final hold = await _holdOf(id);
      if (hold == null) continue;
      if ((hold.branch, hold.worktree) case (final String branch, final String path)) {
        // Held because the branch was in use elsewhere: lifted once it is not.
        if (await worktreeBranch(path) != branch ||
            await _branchBlocker(path, claimed: claimed, runs: [for (final r in runs) r.run]) == null) {
          if (hold.before case final before?) {
            await _write(_holdFile(id), {'reason': before, 'at': _clock.now().toUtc().toIso8601String()});
            held[id] = before;
          } else {
            await _delete(_holdFile(id));
          }
          continue;
        }
        blocked.add(id);
      }
      held[id] = hold.reason;
    }
    return DispatchConditions(
      unavailable: unavailable,
      held: held,
      blocked: blocked,
      runs: [for (final record in runs) record.run],
      sessions: last.sessions,
      starts: last.starts,
      branches: branches,
      problems: await _problems(snapshot),
      epics: {
        ...last.epics,
        for (final record in runs)
          if (record.run.epic) record.run.item,
      },
    );
  }

  /// The problems of the latest run ([_lastRun], which keeps those of the
  /// item session's run) of each unfinished item whose run ended with some.
  Future<Map<ItemId, List<String>>> _problems(BacklogSnapshot snapshot) async {
    final dir = Directory(agentsDir);
    if (!await dir.exists()) return const {};
    final ids = <ItemId>{};
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      for (final suffix in const ['.last.json', '.action.json']) {
        if (entry is File && name.endsWith(suffix)) ids.add(ItemId(name.substring(0, name.length - suffix.length)));
      }
    }
    final problems = <ItemId, List<String>>{};
    for (final id in ids) {
      if (snapshot[id] case final planned? when !planned.isDone) {
        if ((await _lastRun(id))?['problems'] case final List<Object?> list when list.isNotEmpty) {
          problems[id] = [for (final problem in list) '$problem'];
        }
      }
    }
    return problems;
  }

  /// The branch checked out in the worktree at [path]; null when it is
  /// detached, missing or not a git worktree.
  static Future<String?> worktreeBranch(String path) async {
    if (!await Directory(path).exists()) return null;
    try {
      final head = await Process.run('git', ['symbolic-ref', '--quiet', '--short', 'HEAD'], workingDirectory: path);
      return head.exitCode == 0 ? '${head.stdout}'.trim() : null;
    } on ProcessException {
      return null;
    }
  }

  /// The sessions and starts of the last runs (`<id>.last.json`) of items
  /// that are still open or in progress, and which of them ran as epics.
  Future<({Map<ItemId, AgentSession> sessions, Map<ItemId, AgentStart> starts, Set<ItemId> epics})> _sessions(
    BacklogSnapshot snapshot,
  ) async {
    final dir = Directory(agentsDir);
    if (!await dir.exists()) {
      return (sessions: const <ItemId, AgentSession>{}, starts: const <ItemId, AgentStart>{}, epics: const <ItemId>{});
    }
    const suffix = '.last.json';
    final sessions = <ItemId, AgentSession>{};
    final starts = <ItemId, AgentStart>{};
    final epics = <ItemId>{};
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      if (entry is! File || !name.endsWith(suffix)) continue;
      final id = ItemId(name.substring(0, name.length - suffix.length));
      final planned = snapshot[id];
      if (planned == null || planned.isDone) continue;
      try {
        final json = (jsonDecode(await entry.readAsString()) as Map).cast<String, Object?>();
        starts[id] = (at: DateTime.parse(json['started_at']! as String), worktree: json['worktree']! as String);
        if (json['epic'] == true) epics.add(id);
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
    return (sessions: sessions, starts: starts, epics: epics);
  }

  /// Makes git ignore the agents' scratch folder
  /// ([DispatcherConfig.scratchFolder]) in every worktree of the repository
  /// of [path], through its shared `info/exclude` (never committed), so that
  /// the texts an agent writes for the CLI leave its worktree clean.
  static Future<void> ignoreScratch(String path) async {
    final ProcessResult common;
    try {
      common = await Process.run('git', ['rev-parse', '--git-common-dir'], workingDirectory: path);
    } on ProcessException {
      return;
    }
    if (common.exitCode != 0) return;
    final exclude = File(p.join(p.normalize(p.join(path, '${common.stdout}'.trim())), 'info', 'exclude'));
    const entry = '/${DispatcherConfig.scratchFolder}/';
    try {
      final text = await exclude.exists() ? await exclude.readAsString() : '';
      if (LineSplitter.split(text).any((line) => line.trim() == entry)) return;
      await exclude.parent.create(recursive: true);
      await exclude.writeAsString(
        '${text.isEmpty || text.endsWith('\n') ? '' : '\n'}# kanban-ai: texts agents write for the backlog CLI\n'
        '$entry\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // Not fatal: the agent's scratch files would then show as untracked.
    }
  }

  /// Why an agent cannot start in the worktree at [path]; null when it is a
  /// git worktree without uncommitted changes or untracked files. The
  /// agents' scratch folder ([DispatcherConfig.scratchFolder]) does not
  /// count, even where git does not ignore it (yet).
  static Future<String?> worktreeProblem(String path) async {
    if (!await Directory(path).exists()) return 'folder $path does not exist';
    final ProcessResult status;
    try {
      status = await Process.run('git', ['status', '--porcelain'], workingDirectory: path);
    } on ProcessException catch (error) {
      return 'git cannot run: ${error.message}';
    }
    if (status.exitCode != 0) return 'not a git worktree (${_firstLine(status.stderr)})';
    final changes = LineSplitter.split(
      '${status.stdout}',
    ).where((line) => line.trim().isNotEmpty && !_isScratch(line)).length;
    return changes == 0 ? null : 'uncommitted changes ($changes paths)';
  }

  /// A line of `git status --porcelain` about the agents' scratch folder.
  static bool _isScratch(String line) {
    if (line.length < 4) return false;
    var path = line.substring(3);
    if (path.startsWith('"')) path = path.substring(1);
    const folder = DispatcherConfig.scratchFolder;
    return path == folder || path.startsWith('$folder/');
  }

  @override
  Future<void> launch(DispatchAssignment assignment) => _serialized(() async {
    final id = assignment.id;
    final action = assignment.action;
    await _checkIdle(id, assignment.agent);
    final problem = await worktreeProblem(assignment.path);
    if (problem != null) {
      _log('Dispatcher: not starting $id in ${assignment.agent}: $problem.');
      throw UnavailableException('Worktree ${assignment.agent}: $problem.');
    }
    final backlog = await _backlog();
    // An action's agent works on the item without taking it over; an epic's
    // agent takes it with its open children.
    await backlog.claims.claim(
      id.value,
      assignment.agent,
      force: action != null || assignment.epic,
      mirror: action == null,
    );
    final _Record record;
    try {
      final branch = assignment.branch;
      if (branch != null) {
        if (await _freeBranch(assignment, branch) case final problem?) {
          await _branchInUse(backlog, assignment, branch, problem);
        }
        await _checkout(assignment, branch, assignment.base ?? 'main');
        if (assignment.item.item.branch != branch) {
          await backlog.items.update(id.value, [FieldChange.parse('branch=$branch')]);
        }
      }
      record = await _spawn(assignment);
    } catch (_) {
      // A start that failed changes nothing: an action's agent only took the
      // claim, the item's own agent gives the item back in its status.
      if (action != null) {
        await backlog.claims.drop(id.value, assignment.agent);
      } else {
        await backlog.claims.release(id.value, agent: assignment.agent, status: assignment.item.item.status);
      }
      rethrow;
    }
    if (action == null) await _delete(_holdFile(id));
    _lastHeartbeat[id] = _clock.now();
    _log(
      'Dispatcher: started ${assignment.agentProfile.name} for $id in ${assignment.agent} '
      '${action == null ? '' : '(action "${action.name}", ${assignment.trigger.id}) '}'
      '(pid ${record.run.pid}, branch ${assignment.branch ?? '-'}'
      '${assignment.resume == null ? '' : ', resuming session ${assignment.resume!.id}'}, log ${record.run.log}).',
    );
    _onChange?.call();
  });

  /// Fails when something already runs for [id] or in [worktree].
  Future<void> _checkIdle(ItemId id, String? worktree) async {
    if (await _record(id) case final running?) {
      throw UnavailableException(
        '${running.run.action == null ? 'An agent' : 'The action "${running.run.action}"'} already runs for $id.',
      );
    }
    if (worktree == null) return;
    for (final record in await _records()) {
      if (record.run.worktree == worktree) {
        throw UnavailableException('Worktree $worktree is busy with ${record.run.item}.');
      }
    }
  }

  /// Runs an action's command detached (like an agent, with its output in
  /// a log) or its built-in inside this process; nothing is claimed and the
  /// item is left as it is. When it has ended, the exit code and the end of
  /// its output go into the item's discussion as a note.
  @override
  Future<void> runJob(ActionJob job) => _serialized(() async {
    final id = job.id;
    final action = job.action;
    await _checkIdle(id, job.worktree);
    final builtIn = action.builtIn == null ? null : _builtIns[action.builtIn];
    if (action.builtIn != null && builtIn == null) {
      throw UnavailableException('The built-in action "${action.builtIn}" is not available in this server.');
    }
    final now = _clock.now();
    await Directory(agentsDir).create(recursive: true);
    await Directory(logsDir).create(recursive: true);
    final log = p.join(logsDir, '$id-${_stamp(now)}.log');
    await _delete(_exitFile(id));
    await _delete(_stopFile(id));
    final where = job.worktree ?? p.basename(job.path);
    await File(log).writeAsString(
      '# kanban-ai: action "${action.name}" (${job.trigger.id}) for $id in $where (${job.path}), '
      'started ${now.toUtc().toIso8601String()}\n'
      '# ${job.command == null ? 'built-in: ${action.builtIn}' : 'command: ${CommandTemplate.join(job.command!)}'}\n',
      mode: FileMode.append,
    );
    final int pid;
    if (job.command case final command?) {
      final process = await Process.start(
        'sh',
        ['-c', _wrapper, 'kanban-ai-action', log, _exitFile(id), ...command],
        workingDirectory: job.path,
        environment: {..._environment, ...job.environment},
        includeParentEnvironment: false,
        mode: ProcessStartMode.detached,
      );
      pid = process.pid;
    } else {
      pid = io.pid;
    }
    final record = _Record(
      AgentRun(
        item: id,
        worktree: where,
        pid: pid,
        startedAt: now,
        log: log,
        agent: action.name,
        branch: job.values['branch'],
        action: action.name,
        kind: job.command == null ? RunKind.builtIn : RunKind.command,
      ),
      path: job.path,
      pgid: job.command == null ? null : await _processGroup(pid),
      output: AgentOutput.text,
      trigger: job.trigger.id,
    );
    await _write(_recordFile(id), record.toJson());
    if (builtIn != null) {
      _builtInRuns[id] = null;
      unawaited(_runBuiltIn(job, builtIn, log));
    }
    _log(
      'Dispatcher: started the action "${action.name}" for $id in $where (${job.trigger.id}'
      '${job.command == null ? ', built-in ${action.builtIn}' : ', pid $pid'}, log $log).',
    );
    _onChange?.call();
  });

  Future<void> _runBuiltIn(ActionJob job, BuiltInAction builtIn, String log) async {
    final sink = File(log).openWrite(mode: FileMode.append);
    BuiltInActionResult result;
    try {
      final backlog = await _backlog();
      result = await builtIn.run(
        BuiltInActionContext(
          item: job.item,
          action: job.action,
          config: backlog.workflow.dispatcher!,
          backlog: backlog,
          backlogRoot: backlog.root,
          worktree: job.worktree,
          path: job.path,
          values: job.values,
          environment: {..._environment, ...job.environment},
          log: sink.writeln,
          trigger: job.trigger,
          from: job.from,
          stateDir: stateDir,
          project: project,
        ),
      );
    } catch (error) {
      result = BuiltInActionResult(ok: false, summary: 'failed: $error');
    }
    sink.writeln('\n# kanban-ai: the built-in action ${result.ok ? 'succeeded' : 'failed'}: ${result.summary}');
    await sink.close();
    _builtInRuns[job.id] = result;
    await File(_exitFile(job.id)).writeAsString('${result.ok ? 0 : 1}\n');
    await tick();
  }

  /// Ends the run of an action: an agent's claim is dropped (the item keeps
  /// its status, nothing is held), the run is recorded (as the item's last
  /// session unless it was a `fresh` agent, a command or a built-in) and a
  /// note with the result goes into the item's discussion.
  Future<void> _finishAction(_Record record, int? exitCode, String reason, {required bool stopped}) async {
    final run = record.run;
    final id = run.item;
    final backlog = await _backlog();
    final planned = (await backlog.planning.snapshot())[id];
    var outcome = planned == null ? 'the item is gone' : 'the item stays ${planned.item.status}';
    if (planned != null && record.kind == RunKind.agent && planned.claim?.agent == run.worktree) {
      await backlog.claims.drop(id.value, run.worktree);
      outcome = '$outcome, claim dropped';
    }
    final builtIn = record.kind == RunKind.builtIn ? _builtInRuns.remove(id) : null;
    if (record.kind == RunKind.builtIn && builtIn == null && exitCode == null) {
      reason = 'was interrupted (the server stopped while it ran)';
    } else if (builtIn != null) {
      reason = builtIn.ok ? 'succeeded: ${builtIn.summary}' : 'failed: ${builtIn.summary}';
    }
    final claude = record.kind == RunKind.agent && record.output == AgentOutput.claudeStreamJson;
    final session = claude ? await _claudeSession(run.log) ?? record.resumed : record.resumed;
    final end = claude ? await _claudeEnd(run.log) : null;
    final failed = builtIn != null ? !builtIn.ok : !stopped && exitCode != 0;
    // An AI review that ended without its verdict (`backlog review`) is lost work.
    final unrecorded =
        planned != null &&
        !stopped &&
        record.kind == RunKind.agent &&
        backlog.workflow.dispatcher?.action(run.action!)?.review == true &&
        !planned.item.discussion.comments.any(
          (c) => c.review != null && !c.at.isBefore(run.startedAt.subtract(const Duration(seconds: 1))),
        );
    final problems = [
      if (failed) record.kind == RunKind.agent ? 'the agent $reason' : 'the action "${run.action}" $reason',
      if (unrecorded) 'the review was not recorded (no `backlog review`)',
      ...?end?.problems,
    ];
    final ended = _clock.now();
    final side = record.kind != RunKind.agent || record.side;
    // An action that becomes the item's session keeps it an epic.
    final epic = !side && await _lastWasEpic(id);
    await _write(side ? _actionFile(id) : _lastFile(id), {
      ...record.toJson(),
      if (epic) 'epic': true,
      'ended_at': ended.toUtc().toIso8601String(),
      'exit_code': exitCode,
      'reason': reason,
      'outcome': outcome,
      'session_id': session,
      'result': end?.result,
      'problems': problems,
    });
    try {
      await File(
        run.log,
      ).writeAsString('# kanban-ai: the action "${run.action}" $reason; $outcome\n', mode: FileMode.append);
    } on FileSystemException {
      // The log was removed; the outcome is still in the server log.
    }
    for (final file in [_recordFile(id), _exitFile(id), _stopFile(id)]) {
      await _delete(file);
    }
    _lastHeartbeat.remove(id);
    _log('Dispatcher: the action "${run.action}" for $id in ${run.worktree} $reason; $outcome.');
    if (planned == null) return;
    // An agent that did its job says so itself when the action asks for it;
    // only failures, a review without its verdict and the output of commands
    // get a note.
    if (record.kind == RunKind.agent && exitCode == 0 && !unrecorded) return;
    final took = _duration(ended.difference(run.startedAt));
    final where = record.kind == RunKind.agent ? 'agent ${run.agent} in ${run.worktree}' : run.worktree;
    final text = StringBuffer('The action "${run.action}" ($where) $reason after $took.');
    if (unrecorded) {
      text.write(' It recorded no review (`backlog review`), so the review is lost; run the action again.');
    }
    if (record.kind == RunKind.command) {
      final tail = await _outputTail(run.log);
      if (tail.isNotEmpty) {
        final fence = tail.any((line) => line.contains('```')) ? '~~~~' : '```';
        text.write('\n\n${fence}text\n${tail.join('\n')}\n$fence');
      }
    }
    try {
      await backlog.items.comment(id.value, author: noteAuthor, text: text.toString(), note: true);
    } on BacklogException catch (error) {
      _log('Dispatcher: could not add the result of the action to $id: ${error.message}');
    }
  }

  /// The last lines a command wrote (without the launcher's own lines).
  static Future<List<String>> _outputTail(String log, {int lines = 20}) async {
    final file = File(log);
    if (!await file.exists()) return const [];
    final output = [
      for (final line in await file.readAsLines(encoding: const Utf8Codec(allowMalformed: true)))
        if (!line.startsWith('# kanban-ai:') && !line.startsWith('# command:'))
          line.length > 300 ? '${line.substring(0, 300)}…' : line,
    ];
    while (output.isNotEmpty && output.last.trim().isEmpty) {
      output.removeLast();
    }
    return output.length <= lines ? output : output.sublist(output.length - lines);
  }

  static String _duration(Duration duration) => duration.inSeconds < 120
      ? '${duration.inSeconds} s'
      : duration.inMinutes < 120
      ? '${duration.inMinutes} min'
      : '${duration.inHours} h ${duration.inMinutes % 60} min';

  @override
  Future<bool> stop(ItemId item) async {
    final record = await _record(item);
    if (record == null) return false;
    if (record.kind == RunKind.builtIn) {
      throw InvalidInputException('The built-in action "${record.run.action}" of $item cannot be stopped.');
    }
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
      last = await _lastRun(item);
      if (last == null) return null;
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

  @override
  Future<AgentLogSource?> agentLogSource(ItemId item) async {
    if (await _record(item) case final record?) {
      return AgentLogSource(path: record.run.log, running: true, output: record.output);
    }
    final last = await _lastRun(item);
    if (last == null) return null;
    final path = last['log'];
    if (path is! String) return null;
    return AgentLogSource(
      path: path,
      running: false,
      output: AgentOutput.values.firstWhere((o) => o.id == last['output'], orElse: () => AgentOutput.text),
      last: last,
    );
  }

  // ---------------------------------------------------------------- launch

  /// Makes [branch] free for the worktree of [assignment] when another
  /// worktree has it checked out and the dispatcher may detach that one;
  /// returns where it is stuck otherwise (null: free).
  Future<({String path, String why})?> _freeBranch(DispatchAssignment assignment, String branch) async {
    final holder = await _checkedOutIn(assignment.path, branch);
    if (holder == null || MergeAction.samePath(holder, assignment.path)) return null;
    final snapshot = await (await _backlog()).planning.snapshot();
    final why = await _branchBlocker(
      holder,
      claimed: {
        for (final planned in snapshot.items)
          if (planned.isClaimed) planned.claim!.agent,
      },
      runs: [for (final record in await _records()) record.run],
    );
    if (why != null) return (path: holder, why: why);
    final detached = await Process.run('git', ['switch', '--quiet', '--detach'], workingDirectory: holder);
    if (detached.exitCode != 0) {
      return (path: holder, why: 'git switch --detach failed there (${_firstLine(detached.stderr)})');
    }
    _log('Dispatcher: detached ${_managedName(holder)} from $branch for ${assignment.id} in ${assignment.agent}.');
    return null;
  }

  /// Why the dispatcher may not detach the worktree at [path] (null: it may):
  /// it does not manage it, it is busy ([claimed] names, [runs]) or not clean.
  Future<String?> _branchBlocker(String path, {required Set<String> claimed, required List<AgentRun> runs}) async {
    final name = _managedName(path);
    if (name == null) return 'a worktree the dispatcher does not manage';
    if (claimed.contains(name) || runs.any((run) => run.worktree == name)) return 'the worktree $name, which is busy';
    if (await worktreeProblem(path) case final problem?) return 'the worktree $name, which has $problem';
    return null;
  }

  String? _managedName(String path) =>
      _managed.entries.firstWhereOrNull((w) => MergeAction.samePath(w.value, path))?.key;

  /// The worktree (of the repository of [path]) that has [branch] checked
  /// out; null when none.
  static Future<String?> _checkedOutIn(String path, String branch) async {
    final list = await Process.run('git', ['worktree', 'list', '--porcelain'], workingDirectory: path);
    if (list.exitCode != 0) return null;
    String? worktree;
    for (final line in LineSplitter.split('${list.stdout}')) {
      if (line.startsWith('worktree ')) worktree = line.substring('worktree '.length);
      if (line == 'branch refs/heads/$branch') return worktree;
    }
    return null;
  }

  /// Fails the launch of [assignment] because [branch] is stuck in another
  /// worktree: an agent's item is held (noted in its discussion the first
  /// time), a prompt action fails for good.
  Future<Never> _branchInUse(
    Backlog backlog,
    DispatchAssignment assignment,
    String branch,
    ({String path, String why}) problem,
  ) async {
    final id = assignment.id;
    final message =
        'Cannot start in ${assignment.agent}: the branch $branch is checked out in ${problem.why} '
        '(${problem.path}). Free it there (git switch --detach) and start $id again.';
    if (assignment.action != null) throw InvalidInputException(message);
    final previous = await _holdOf(id);
    await _write(_holdFile(id), {
      'reason': message,
      'at': _clock.now().toUtc().toIso8601String(),
      'branch': branch,
      'worktree': problem.path,
      // An earlier hold (the agent left it unfinished) comes back afterwards.
      'before': ?(previous == null ? null : previous.before ?? (previous.branch == null ? previous.reason : null)),
    });
    if (previous?.branch != branch || previous?.worktree != problem.path) {
      _log('Dispatcher: held $id: $message');
      try {
        await backlog.items.comment(id.value, author: noteAuthor, text: '$message Held until then.', note: true);
      } on BacklogException catch (error) {
        _log('Dispatcher: could not add a note to $id: ${error.message}');
      }
      _onChange?.call();
    }
    throw UnavailableException(message);
  }

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
    final action = assignment.action;
    // Once an epic, the item's own runs stay the epic's (replies, fixes).
    final epic = action == null && (assignment.epic || await _lastWasEpic(id));
    await ignoreScratch(assignment.path);
    await File(log).writeAsString(
      '# kanban-ai: ${assignment.agentProfile.name} for ${epic ? 'the epic ' : ''}$id'
      '${action == null ? '' : ' (action "${action.name}", ${assignment.trigger.id})'} in ${assignment.agent} (${assignment.path}), '
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
        action: action?.name,
        epic: epic,
      ),
      path: assignment.path,
      pgid: await _processGroup(process.pid),
      output: assignment.agentProfile.output,
      resumed: assignment.resume?.id,
      side: action?.fresh ?? false,
      trigger: action == null ? null : assignment.trigger.id,
    );
    await _write(_recordFile(id), record.toJson());
    return record;
  }

  // ------------------------------------------------------------ supervise

  Future<void> _heartbeat(_Record record) async {
    if (record.kind != RunKind.agent) return; // commands and built-ins hold no claim
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
    if (!record.run.epic) return;
    // An epic's agent also holds the item of the epic it works on.
    for (final claim in await backlog.claims.all()) {
      if (claim.agent != record.run.worktree || claim.itemId == id || claim.isExpiredAt(now)) continue;
      try {
        await backlog.claims.heartbeat(claim.itemId.value, claim.agent);
      } on BacklogException {
        // Released meanwhile.
      }
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

    if (record.run.action != null) return _finishAction(record, exitCode, reason, stopped: stopped);

    final backlog = await _backlog();
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[id];
    var outcome = '';
    var handedOver = false;
    final members = run.epic ? await _releaseMembers(backlog, snapshot, record) : '';
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
        handedOver = backlog.workflow.categoryOf(planned.item.status) == StatusCategory.active;
      }
    } else {
      outcome =
          'the item is ${planned.item.status}${planned.claim == null ? '' : ', claimed by ${planned.claim!.agent}'}';
    }
    final session = record.output == AgentOutput.claudeStreamJson
        ? await _claudeSession(run.log) ?? record.resumed
        : record.resumed;
    final end = record.output == AgentOutput.claudeStreamJson ? await _claudeEnd(run.log) : null;
    final problems = [if (!stopped && exitCode != 0) 'the agent $reason', ...?end?.problems];
    if (handedOver && planned != null) {
      if (await _pullRequestFallback(backlog, record, planned.item, end?.result) case final done?) {
        outcome = '$outcome; ${done.text}';
        if (done.failed) problems.add(done.text);
      }
    }
    if (members.isNotEmpty) outcome = '$outcome; $members';
    final ended = _clock.now();
    await _write(_lastFile(id), {
      ...record.toJson(),
      'ended_at': ended.toUtc().toIso8601String(),
      'exit_code': exitCode,
      'reason': reason,
      'outcome': outcome,
      'session_id': session,
      'result': end?.result,
      'problems': problems,
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

  /// After an epic's agent ended: the claims it still holds on items under
  /// the epic are dropped — an item still in the first active status goes
  /// back to the pickable status (its next run takes it up again), one
  /// handed over keeps its status. Returns what happened for the outcome
  /// (empty when nothing).
  Future<String> _releaseMembers(Backlog backlog, BacklogSnapshot snapshot, _Record record) async {
    final worktree = record.run.worktree;
    final released = <ItemId>[];
    final dropped = <ItemId>[];
    for (final planned in snapshot.items) {
      if (!planned.ancestors.contains(record.run.item) || planned.claim?.agent != worktree) continue;
      if (planned.item.status == backlog.workflow.activeStatus) {
        await backlog.claims.release(planned.id.value, agent: worktree, force: true);
        released.add(planned.id);
      } else {
        // Handed over by the epic's agent: its work is on the epic's branch,
        // which reviews and the merge go by.
        final branch = record.run.branch;
        if (branch != null && planned.item.branch?.trim() != branch) {
          await backlog.items.update(planned.id.value, [FieldChange.parse('branch=$branch')]);
        }
        await backlog.claims.drop(planned.id.value, worktree);
        dropped.add(planned.id);
      }
    }
    return [
      if (released.isNotEmpty) 'released the unfinished ${released.join(', ')}',
      if (dropped.isNotEmpty) 'dropped the claims on ${dropped.join(', ')}',
    ].join('; ');
  }

  /// The safety net for `dispatcher.pr`: an agent handed its item over
  /// (e.g. to `review`) without a pull request — it did not run
  /// `backlog pr`, or that failed. Pushes the branch and opens one with the
  /// agent's last message (or its last comment, else a description made
  /// from the item) and notes the result in the discussion; on failure the
  /// note says why and the item stays where the agent put it. Returns what
  /// happened for the log and whether it failed; null when there is nothing
  /// to do.
  Future<({String text, bool failed})?> _pullRequestFallback(
    Backlog backlog,
    _Record record,
    Item item,
    String? result,
  ) async {
    if (backlog.workflow.dispatcher?.pr == null) return null;
    if (item.pr case final pr? when pr.trim().isNotEmpty) return null;
    final branch = item.branch ?? record.run.branch;
    if (branch == null) return null;
    final base = backlog.workflow.dispatcher!.base;
    final ahead = await Process.run('git', ['rev-list', '--count', '$base..$branch'], workingDirectory: record.path);
    if (ahead.exitCode == 0 && '${ahead.stdout}'.trim() == '0') {
      await _note(backlog, item, 'No pull request: $branch has no commits that are not in $base.');
      return (text: 'no pull request ($branch has no commits of its own)', failed: false);
    }
    final description = result ?? _lastComment(item, record.run.worktree);
    try {
      final opened = await PullRequestOpener(
        environment: _environment,
      ).open(backlog, item.id.value, workingDirectory: record.path, description: description);
      await _note(
        backlog,
        item,
        opened.created
            ? 'The agent handed over without a pull request; pushed $branch and opened ${opened.url}'
            : 'The agent handed over without recording its pull request; pushed $branch, found ${opened.url}',
      );
      return (text: 'opened its pull request ${opened.url}', failed: false);
    } on BacklogException catch (error) {
      await _note(
        backlog,
        item,
        'Could not open a pull request for $branch: ${error.message}\n\n'
        'The item stays ${item.status}; `backlog pr ${item.id}` in ${record.run.worktree} tries again.',
      );
      return (text: 'opening its pull request failed: ${error.message}', failed: true);
    }
  }

  static Future<void> _note(Backlog backlog, Item item, String text) =>
      backlog.items.comment(item.id.value, author: dispatcherAuthor, text: text, note: true);

  /// The author of the dispatcher's notes in a discussion.
  static const dispatcherAuthor = 'dispatcher';

  static String? _lastComment(Item item, String agent) {
    final own = Discussion.parse(item.body).comments.where((c) => c.author == agent && !c.question);
    return own.isEmpty ? null : own.last.text;
  }

  /// How a Claude run ended, from its last `result` event: the agent's final
  /// message and what went wrong (an error ending, denied tool calls).
  static Future<({String? result, List<String> problems})> _claudeEnd(String log) async {
    final file = File(log);
    if (!await file.exists()) return (result: null, problems: const <String>[]);
    Map<Object?, Object?>? end;
    for (final line in await file.readAsLines(encoding: const Utf8Codec(allowMalformed: true))) {
      if (!line.startsWith('{') || !line.contains('"type":"result"')) continue;
      try {
        if (jsonDecode(line) case final Map<Object?, Object?> json when json['type'] == 'result') end = json;
      } on FormatException {
        continue;
      }
    }
    if (end == null) return (result: null, problems: const <String>[]);
    final result = switch (end['result']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    final denials = [
      if (end['permission_denials'] case final List<Object?> list)
        for (final denial in list)
          if (denial case final Map<Object?, Object?> denial)
            if (denial['tool_name'] case final String tool) _denied(tool, denial['tool_input']),
    ];
    return (
      result: result,
      problems: [
        if (end['is_error'] == true) 'the agent ended with an error (${end['subtype'] ?? 'unknown'})',
        if (denials.isNotEmpty)
          '${denials.length == 1 ? 'a tool call was' : '${denials.length} tool calls were'} denied: '
              '${denials.toSet().take(5).join(', ')}${denials.toSet().length > 5 ? ', …' : ''}',
      ],
    );
  }

  /// `Bash(git push origin x)`, `WebFetch`: a denied tool call, shortened.
  static String _denied(String tool, Object? input) {
    final detail = switch (input) {
      {'command': final String command} => command,
      {'file_path': final String path} => path,
      _ => null,
    };
    if (detail == null) return tool;
    final line = detail.trim().split('\n').first;
    return '$tool(${line.length > 60 ? '${line.substring(0, 60)}…' : line})';
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
    if (record.kind == RunKind.builtIn) return _builtInRuns.containsKey(record.run.item);
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

  /// The last run of an action that is not the item's session (a command, a
  /// built-in or a `fresh` agent).
  String _actionFile(ItemId id) => p.join(agentsDir, '$id.action.json');

  /// How the latest run for [id] ended: of `<id>.last.json` and
  /// `<id>.action.json` the one that ended last; null when none ran.
  ///
  /// The problems of the item session's run hold until its next run: after
  /// them an action without problems (an AI review on entering review) does
  /// not count, and the problems of one that has some are added to them.
  Future<Map<String, Object?>?> _lastRun(ItemId id) async {
    final agent = await _readJson(_lastFile(id));
    final action = await _readJson(_actionFile(id));
    if (agent == null || action == null) return agent ?? action;
    DateTime? ended(Map<String, Object?> run) => DateTime.tryParse(run['ended_at'] as String? ?? '');
    final (agentEnded, actionEnded) = (ended(agent), ended(action));
    if (actionEnded == null || (agentEnded != null && actionEnded.isBefore(agentEnded))) return agent;
    List<Object?> problems(Map<String, Object?> run) => run['problems'] as List<Object?>? ?? const [];
    if (problems(agent).isEmpty) return action;
    if (problems(action).isEmpty) return agent;
    return {
      ...action,
      'problems': [...problems(agent), ...problems(action)],
    };
  }

  Future<Map<String, Object?>?> _readJson(String file) async {
    final text = await _read(file);
    if (text == null) return null;
    try {
      return (jsonDecode(text) as Map).cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  /// The last run of [id]'s own agent implemented it as an epic.
  Future<bool> _lastWasEpic(ItemId id) async {
    final text = await _read(_lastFile(id));
    if (text == null) return false;
    try {
      return (jsonDecode(text) as Map)['epic'] == true;
    } on FormatException {
      return false;
    }
  }

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
      if (entry is! File ||
          !name.endsWith('.json') ||
          name.endsWith('.hold.json') ||
          name.endsWith('.last.json') ||
          name.endsWith('.action.json')) {
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

  /// Why [id] is held; for a branch in use elsewhere also the branch, the
  /// worktree path that has it and the hold it replaced ([before]).
  Future<({String reason, String? branch, String? worktree, String? before})?> _holdOf(ItemId id) async {
    final text = await _read(_holdFile(id));
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map;
      return (
        reason: '${json['reason']}',
        branch: json['branch'] as String?,
        worktree: json['worktree'] as String?,
        before: json['before'] as String?,
      );
    } on FormatException {
      return (reason: 'held', branch: null, worktree: null, before: null);
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

/// What `agents/<project>/<id>.json` holds about a running agent, action
/// command or built-in.
final class _Record {
  _Record(
    this.run, {
    required this.path,
    required this.pgid,
    required this.output,
    this.resumed,
    this.side = false,
    this.trigger,
  });

  factory _Record.fromJson(Map<String, Object?> json) => _Record(
    AgentRun(
      item: ItemId(json['item']! as String),
      worktree: json['worktree']! as String,
      pid: json['pid']! as int,
      startedAt: DateTime.parse(json['started_at']! as String),
      log: json['log']! as String,
      agent: json['agent'] as String? ?? '?',
      branch: json['branch'] as String?,
      action: json['action'] as String?,
      kind: RunKind.parse(json['kind']),
      epic: json['epic'] == true,
    ),
    path: json['path']! as String,
    pgid: json['pgid'] as int?,
    output: AgentOutput.values.firstWhere((o) => o.id == json['output'], orElse: () => AgentOutput.text),
    resumed: json['resumed'] as String?,
    side: json['side'] == true,
    trigger: json['trigger'] as String?,
  );

  final AgentRun run;

  /// Absolute path of the worktree (the working directory).
  final String path;

  /// Process group of the agent (its own session); signalled by `stop`.
  final int? pgid;
  final AgentOutput output;

  /// The session this run continues; null for a new one.
  final String? resumed;

  /// A `fresh` action agent: its session does not become the item's.
  final bool side;

  /// Why the action runs (`request`, `on_enter`); null for agents of the
  /// item's own work.
  final String? trigger;

  RunKind get kind => run.kind;

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
    if (run.epic) 'epic': true,
    if (run.action != null) ...{'action': run.action, 'kind': run.kind.id, 'side': side, 'trigger': trigger},
  };
}
