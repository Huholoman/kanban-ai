import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../backlog.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/planned_item.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/dispatch_plan.dart';
import '../domain/pull_request_state.dart';
import 'built_in_actions.dart';
import 'merge_action.dart';

/// Notices pull requests merged (or closed) outside the board
/// (`dispatcher.pr.state`): at most every `state_every` minutes it asks
/// for the state of the pull request of every item in an `active` status
/// with a `pr`, that is not claimed and for which nothing runs. A merged one
/// makes the item done and is cleaned up like after the action `merge`
/// ([MergeCleanup], with `dispatcher.merge.cleanup`); a closed one gets a
/// note, once per pull request. Both are notes by `kanban-ai`. What it saw
/// last is kept in `pull-requests/<project>/<id>.json` under [stateDir].
final class PullRequestWatcher {
  PullRequestWatcher({
    required this.project,
    required this.stateDir,
    required Future<Backlog> Function() backlog,
    required Future<bool> Function(ItemId item) running,
    required Future<T> Function<T>(Future<T> Function() action) serialized,
    Clock clock = const SystemClock(),
    Map<String, String>? environment,
    void Function(String message)? log,
    this.timeout = const Duration(seconds: 30),
  }) : _backlog = backlog,
       _running = running,
       _serialized = serialized,
       _clock = clock,
       _environment = environment,
       _log = log ?? ((_) {});

  final String project;
  final String stateDir;
  final Duration timeout;
  final Future<Backlog> Function() _backlog;
  final Future<bool> Function(ItemId item) _running;
  final Future<T> Function<T>(Future<T> Function() action) _serialized;
  final Clock _clock;
  final Map<String, String>? _environment;
  final void Function(String message) _log;
  DateTime? _last;
  bool _polling = false;

  String get _dir => p.join(stateDir, 'pull-requests', project);

  /// Checks the pull requests when `state_every` has passed since the last
  /// time (or [force]); returns the items it made done.
  Future<List<ItemId>> poll({bool force = false}) async {
    if (_polling) return const [];
    final backlog = await _backlog();
    final config = backlog.workflow.dispatcher;
    final pr = config?.pr;
    final state = pr?.state;
    if (config == null || pr == null || state == null) return const [];
    final now = _clock.now();
    if (!force && _last != null && now.difference(_last!) < pr.stateEvery) return const [];
    _polling = true;
    _last = now;
    final merged = <ItemId>[];
    try {
      final snapshot = await backlog.planning.snapshot();
      final repo = await MergeAction.primaryClone(config, backlog.root, null) ?? backlog.root;
      for (final planned in snapshot.items) {
        final url = planned.item.pr?.trim() ?? '';
        if (url.isEmpty || planned.isClaimed || await _running(planned.id)) continue;
        if (backlog.workflow.categoryOf(planned.item.status) != StatusCategory.active) continue;
        final values = _values(planned, config, url);
        if (state.arguments.any((a) => a.contains('{pr_number}')) && values['pr_number']!.isEmpty) continue;
        final result = await _run(state.render(values), repo);
        final seen = result == null || result.exitCode != 0
            ? PullRequestState.unknown
            : PullRequestState.parse(result.output);
        if (seen == PullRequestState.unknown) {
          _log(
            'Dispatcher: the state of ${planned.id}\'s pull request $url is unknown'
            '${result == null ? '' : ' (exit code ${result.exitCode}: ${_firstLine(result.output)})'}.',
          );
          continue;
        }
        final before = await _seen(planned.id);
        await _remember(planned.id, url, seen);
        if (seen == PullRequestState.merged) {
          if (await _serialized(() => _merged(planned.id, url))) merged.add(planned.id);
        } else if (seen == PullRequestState.closed && (before?.url != url || before?.state != seen)) {
          await _note(
            backlog,
            planned.id,
            'The pull request $url was closed without being merged; ${planned.id} stays ${planned.item.status}.',
          );
        }
      }
    } on Object catch (error) {
      _log('Dispatcher: checking pull requests failed: $error');
    } finally {
      _polling = false;
    }
    return merged;
  }

  /// The item is done, its branch and worktree are cleaned up; false when
  /// it changed in the meantime.
  Future<bool> _merged(ItemId id, String url) async {
    final backlog = await _backlog();
    final config = backlog.workflow.dispatcher!;
    final planned = (await backlog.planning.snapshot())[id];
    if (planned == null ||
        planned.isClaimed ||
        planned.item.pr?.trim() != url ||
        backlog.workflow.categoryOf(planned.item.status) != StatusCategory.active ||
        await _running(id)) {
      return false;
    }
    await backlog.claims.complete(id.value, force: true);
    final status = (await backlog.items.get(id.value)).status;
    final steps = <String>[];
    if (config.merge.cleanup) {
      final repo = await MergeAction.primaryClone(config, backlog.root, null);
      if (repo != null) {
        steps.addAll(
          await MergeCleanup(
            config: config,
            backlogRoot: backlog.root,
            repo: repo,
            stateDir: stateDir,
            project: project,
            exec: (command, path) async =>
                await _run(command, path) ?? const CommandOutput(124, 'did not finish in time'),
          ).run(id, DispatchAssignment.branchFor(planned)),
        );
      }
    }
    _log('Dispatcher: the pull request $url of $id was merged; $id is $status.');
    await _note(
      backlog,
      id,
      'The pull request $url was merged outside the board; $id is $status${steps.map((s) => '; $s').join()}.',
    );
    return true;
  }

  Map<String, String> _values(PlannedItem planned, DispatcherConfig config, String url) => {
    'id': planned.id.value,
    'title': planned.item.title,
    'branch': DispatchAssignment.branchFor(planned),
    'base': config.base,
    'remote': config.pr!.remote,
    'pr': url,
    'pr_number': PullRequestConfig.numberOf(url) ?? '',
  };

  Future<CommandOutput?> _run(List<String> command, String path) async {
    try {
      final result = await Process.run(
        command.first,
        command.skip(1).toList(),
        workingDirectory: path,
        environment: _environment,
      ).timeout(timeout);
      return CommandOutput(result.exitCode, '${result.stdout}${result.stderr}');
    } on ProcessException catch (error) {
      return CommandOutput(127, error.message);
    } on TimeoutException {
      return null;
    }
  }

  Future<({String url, PullRequestState state})?> _seen(ItemId id) async {
    try {
      final json = jsonDecode(await File(p.join(_dir, '$id.json')).readAsString()) as Map;
      return (
        url: '${json['url']}',
        state: PullRequestState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => PullRequestState.unknown,
        ),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _remember(ItemId id, String url, PullRequestState state) async {
    await Directory(_dir).create(recursive: true);
    await File(p.join(_dir, '$id.json')).writeAsString(
      '${jsonEncode({'url': url, 'state': state.name, 'checked_at': _clock.now().toUtc().toIso8601String()})}\n',
    );
  }

  Future<void> _note(Backlog backlog, ItemId id, String text) async {
    try {
      await backlog.items.comment(id.value, author: 'kanban-ai', text: text, note: true);
    } on BacklogException catch (error) {
      _log('Dispatcher: could not add a note to $id: ${error.message}');
    }
  }

  static String _firstLine(String text) => text.trim().split('\n').first;
}
