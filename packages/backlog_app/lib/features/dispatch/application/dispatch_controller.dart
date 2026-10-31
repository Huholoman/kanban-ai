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
    _changes ??= DebouncedChanges(
      _api,
      (_) => unawaited(load()),
      delay: _refreshDelay,
      watched: const {BacklogPart.workflow, BacklogPart.items, BacklogPart.plan},
    );
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

  /// Whether a start of [item] would continue the session of its last
  /// agent: there is one and its worktree is free.
  bool canResume(String item) {
    final session = plan.sessionFor(item);
    return session != null && plan.worktrees.any((w) => w.name == session.worktree && w.isFree);
  }

  /// Starts an agent for [item]: it continues the item's last session when
  /// it can, unless [fresh]; otherwise a new one in the first free worktree.
  Future<void> startAgent(String item, {bool fresh = false}) => _act(item, () async {
    final resuming = !fresh && canResume(item);
    plan = await _api.startAgent(item, fresh: fresh);
    final run = plan.runFor(item);
    final verb = resuming ? 'Continued' : 'Started';
    _notices.add(run == null ? '$verb an agent for $item.' : '$verb ${run.agent} for $item in ${run.worktree}.');
  });

  /// Whether an action can start on [item] now: a dispatcher runs and
  /// nothing runs for the item yet.
  bool canRunAction(String item) => configured && runFor(item) == null && !pending.contains(item);

  /// The `on_enter` actions waiting to run for [item].
  List<PendingActionDto> pendingActionsFor(String item) => plan.pendingFor(item);

  /// Starts the configured action [name] on [item].
  Future<void> runAction(String item, String name) => _act(item, () async {
    plan = await _api.runAction(item, name);
    final run = plan.runFor(item);
    _notices.add(switch (run) {
      null => 'Started "$name" for $item.',
      AgentRunDto(kind: 'agent') => 'Started "$name" for $item: ${run.agent} in ${run.worktree}.',
      _ => 'Started "$name" for $item in ${run.worktree}.',
    });
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
