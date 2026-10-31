import 'dart:async';

import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/dispatch_plan.dart';

/// Creates a one-shot timer; [Timer.new] by default, a fake one in tests.
typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Keeps a [DispatchPlan] up to date and, in [DispatchMode.auto], hands its
/// assignments to an [AgentLauncher].
///
/// Whoever watches the backlog calls [notifyChanged]; bursts of changes are
/// collected for [debounce] and evaluated once. Evaluations never overlap,
/// and the dispatcher wakes up by itself when a live claim expires
/// ([DispatchPlan.recheckAt]), since that changes the plan without touching
/// any file, and every [unavailableRecheck] while a worktree is unavailable
/// (uncommitted changes are not watched). An assignment is launched once; it
/// is tried again only after it dropped out of the plan or its launch
/// failed. [start] launches one item by hand, in either mode.
final class Dispatcher {
  Dispatcher({
    required Future<BacklogSnapshot> Function() snapshot,
    required this.backlogRoot,
    required AgentLauncher launcher,
    required Clock clock,
    this.debounce = const Duration(milliseconds: 500),
    this.unavailableRecheck = const Duration(seconds: 30),
    TimerFactory timer = Timer.new,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _snapshot = snapshot,
       _launcher = launcher,
       _clock = clock,
       _timer = timer,
       _onError = onError ?? Zone.current.handleUncaughtError;

  final String backlogRoot;
  final Duration debounce;
  final Duration unavailableRecheck;
  final Future<BacklogSnapshot> Function() _snapshot;
  final AgentLauncher _launcher;
  final Clock _clock;
  final TimerFactory _timer;
  final void Function(Object error, StackTrace stackTrace) _onError;
  final _plans = StreamController<DispatchPlan?>.broadcast(sync: true); // before any launch it causes
  final _launched = <String>{};
  Future<void> _queue = Future.value();
  Timer? _debounceTimer;
  Timer? _recheckTimer;
  DispatchPlan? _current;
  bool _closed = false;

  /// The latest plan; null before the first evaluation or without a
  /// dispatcher section.
  DispatchPlan? get current => _current;

  /// Every plan that differs from the previous one ([DispatchPlan.sameDecisionAs]);
  /// null when the dispatcher section got removed.
  Stream<DispatchPlan?> get plans => _plans.stream;

  /// Something in the backlog changed; evaluate after [debounce] of quiet.
  void notifyChanged() {
    if (_closed) return;
    _debounceTimer?.cancel();
    _debounceTimer = _timer(debounce, () {
      _debounceTimer = null;
      unawaited(evaluate());
    });
  }

  /// Evaluates now (after any evaluation already running) and returns the
  /// plan; errors go to `onError` and leave the previous plan in place.
  Future<DispatchPlan?> evaluate() => _serialized(_evaluate);

  /// Starts the ready item [reference] now, whatever the mode, and returns
  /// what was started: the agent continues the item's last session in its
  /// worktree when it can, unless [fresh]; else it starts in the first free
  /// worktree. Fails with
  /// `NotFoundException` without a dispatcher, `InvalidInputException` when
  /// the item is not ready, `UnavailableException` when no worktree is free
  /// and `ClaimConflictException` when someone else claimed it first.
  Future<DispatchAssignment> start(String reference, {bool fresh = false}) => _serialized(() async {
    final plan = await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final assignment = plan.assignmentFor(reference, fresh: fresh);
    await _launcher.launch(assignment);
    _launched.add(assignment.key);
    await _evaluate();
    return assignment;
  });

  /// Stops the agent working on [reference]; false when none ran.
  Future<bool> stop(String reference) => _serialized(() async {
    final plan = _current ?? await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final id = ItemReference.resolve(reference, plan.snapshot.ids);
    final stopped = await _launcher.stop(id);
    await _evaluate();
    return stopped;
  });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> close() async {
    _closed = true;
    _debounceTimer?.cancel();
    _recheckTimer?.cancel();
    await _queue;
    await _plans.close();
  }

  Future<DispatchPlan?> _evaluate({bool launchAuto = true}) async {
    if (_closed) return _current;
    final DispatchPlan? plan;
    try {
      final snapshot = await _snapshot();
      final config = snapshot.workflow.dispatcher;
      plan = DispatchPlan.of(
        snapshot,
        backlogRoot: backlogRoot,
        conditions: config == null
            ? DispatchConditions.none
            : await _launcher.conditions(config, backlogRoot, snapshot),
      );
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
      return _current;
    }
    if (_closed) return _current;

    final changed = plan == null ? _current != null : !plan.sameDecisionAs(_current);
    _current = plan;
    if (changed) _plans.add(plan);
    var recheckAt = plan?.recheckAt;
    if (plan != null && plan.hasUnavailable) {
      final soon = _clock.now().add(unavailableRecheck);
      if (recheckAt == null || soon.isBefore(recheckAt)) recheckAt = soon;
    }
    _scheduleRecheck(recheckAt);

    final keys = {...?plan?.assignments.map((a) => a.key)};
    _launched.retainAll(keys);
    if (launchAuto && plan != null && plan.mode == DispatchMode.auto) {
      for (final assignment in plan.assignments) {
        if (!_launched.add(assignment.key)) continue;
        try {
          await _launcher.launch(assignment);
        } catch (error, stackTrace) {
          _launched.remove(assignment.key);
          _onError(error, stackTrace);
        }
      }
    }
    return plan;
  }

  void _scheduleRecheck(DateTime? at) {
    _recheckTimer?.cancel();
    _recheckTimer = null;
    if (at == null) return;
    final delay = at.difference(_clock.now());
    _recheckTimer = _timer(delay.isNegative ? Duration.zero : delay, () {
      _recheckTimer = null;
      unawaited(evaluate());
    });
  }
}

/// An [AgentLauncher] that starts nothing and only reports what it would
/// run; the default until agents can really be started.
final class LoggingLauncher extends AgentLauncher {
  LoggingLauncher(this._log);

  final void Function(String message) _log;

  @override
  Future<void> launch(DispatchAssignment assignment) async {
    _log(
      'Dispatcher: would start ${assignment.id} in ${assignment.agent} (${assignment.path}): '
      '${CommandTemplate.join(assignment.command)}',
    );
  }
}
