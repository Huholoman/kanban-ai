import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';

/// The dispatcher's plan for the board: which worktrees are busy, which
/// agents run, what would start next; and the *Start* / *Stop* actions.
/// Reloads when the server reports a new plan or changed files.
class DispatchController extends ChangeNotifier {
  DispatchController(this._api, {Duration refreshDelay = const Duration(milliseconds: 300)})
    : _refreshDelay = refreshDelay;

  final BacklogApi _api;
  final Duration _refreshDelay;
  final _notices = StreamController<String>.broadcast();
  DebouncedChanges? _changes;
  bool _disposed = false;

  /// [DispatchDto.off] until loaded, without a dispatcher, and when the
  /// server does not know the dispatcher API.
  DispatchDto plan = DispatchDto.off;

  /// Items whose start or stop is under way.
  Set<String> pending = const {};

  /// Success and failure messages of [start] and [stop].
  Stream<String> get notices => _notices.stream;

  bool get configured => plan.configured;

  Future<void> start() async {
    _changes ??= DebouncedChanges(_api, () => unawaited(load()), delay: _refreshDelay, dispatch: true);
    await load();
  }

  Future<void> load() async {
    try {
      plan = await _api.dispatch();
    } on BacklogApiException {
      plan = DispatchDto.off; // an older server, or a broken backlog the board reports itself
    }
    if (!_disposed) notifyListeners();
  }

  /// The agent running for [item], if any.
  AgentRunDto? runFor(String item) => plan.runFor(item);

  /// Whether [item] can get an agent now: a dispatcher, the item ready, a
  /// free worktree within `max_agents`, nothing running for it yet.
  bool canStart(ItemDto item) =>
      plan.canStart && item.ready && !item.isDone && runFor(item.id) == null && !pending.contains(item.id);

  /// Starts an agent for [item] in the first free worktree.
  Future<void> startAgent(String item) => _act(item, () async {
    plan = await _api.startAgent(item);
    final run = plan.runFor(item);
    _notices.add(run == null ? 'Started an agent for $item.' : 'Started ${run.agent} for $item in ${run.worktree}.');
  });

  /// Stops the agent of [item]; the item goes back to the queue, held.
  Future<void> stopAgent(String item) => _act(item, () async {
    plan = await _api.stopAgent(item);
    _notices.add('Stopped the agent of $item.');
  });

  Future<void> _act(String item, Future<void> Function() action) async {
    pending = {...pending, item};
    notifyListeners();
    try {
      await action();
    } on BacklogApiException catch (error) {
      _notices.add(error.message);
    } finally {
      pending = {...pending}..remove(item);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}
