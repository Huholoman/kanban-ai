import 'dart:async';

import 'package:collection/collection.dart';

import '../../items/domain/discussion.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/epic_plan.dart';
import '../../planning/domain/review_state.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/action_definition.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/action_run.dart';
import '../domain/dispatch_plan.dart';

/// Creates a one-shot timer; [Timer.new] by default, a fake one in tests.
typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Keeps a [DispatchPlan] up to date and, in [DispatchMode.auto], hands its
/// assignments to an [AgentLauncher]; in [DispatchMode.manual] only those
/// that wake an agent a person replied to ([DispatchPlan.isReply]).
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
    ActionStateStore? actions,
    ActionRequests? requests,
    Future<void> Function(ItemId item, String text)? note,
    void Function(String message)? log,
  }) : _snapshot = snapshot,
       _launcher = launcher,
       _clock = clock,
       _timer = timer,
       _onError = onError ?? Zone.current.handleUncaughtError,
       _actions = actions ?? MemoryActionStateStore(),
       _requests = requests,
       _note = note,
       _log = log ?? ((_) {});

  final String backlogRoot;
  final Duration debounce;
  final Duration unavailableRecheck;
  final Future<BacklogSnapshot> Function() _snapshot;
  final AgentLauncher _launcher;
  final Clock _clock;
  final TimerFactory _timer;
  final void Function(Object error, StackTrace stackTrace) _onError;
  final ActionStateStore _actions;
  final ActionRequests? _requests;

  /// Adds a note to an item's discussion (why a requested action could not
  /// start); null leaves it to the log.
  final Future<void> Function(ItemId item, String text)? _note;
  final void Function(String message) _log;
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

  /// Starts one agent that implements the epic [reference] — all items under
  /// it, on its branch — now, whatever the mode ([DispatchPlan.epicStart]);
  /// returns what was started. Fails like [start], and with
  /// `InvalidInputException` when the epic cannot be implemented
  /// ([EpicVerdict.forbidden]).
  Future<DispatchAssignment> startEpic(String reference, {bool fresh = false}) => _serialized(() async {
    final plan = await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final assignment = plan.epicStart(reference, fresh: fresh);
    await _launcher.launch(assignment);
    _launched.add(assignment.key);
    await _evaluate();
    return assignment;
  });

  /// Starts the action [name] on [reference] now, as a person asked
  /// ([ActionTrigger.request]), whatever the mode; returns what started
  /// (`agent claude in wt-2`, `command in wt-2`, …). Fails like
  /// [DispatchPlan.actionStart], and with `NotFoundException` without a
  /// dispatcher.
  Future<String> runAction(String reference, String name) => _serialized(() async {
    final plan = await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final started = await _startAction(plan, reference, name, ActionTrigger.request);
    await _evaluate();
    return started;
  });

  /// Starts what a person asked for ([start]: the item's agent, an epic or
  /// an action) now, whatever the mode, or queues it when it cannot start
  /// yet: no free worktree, `max_agents` reached, something already runs
  /// for the item or holds its claim, its branch busy in another worktree.
  /// Returns null when it started, else the queued start (one per item: a
  /// new request replaces the item's queued one in its place). A request
  /// that can never start (the item done, not ready, an action its status
  /// does not offer, …) fails like [start], [startEpic] and [runAction].
  Future<QueuedStart?> request(QueuedStart start) => _serialized(() async {
    final plan = await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final id = ItemReference.resolve(start.item.value, plan.snapshot.ids);
    final asked = QueuedStart(
      item: id,
      kind: start.kind,
      since: start.since,
      action: start.action,
      fresh: start.fresh,
      by: start.by,
    );
    QueuedStart? queued;
    try {
      final started = await _launchStart(plan, asked);
      _log('Dispatcher: ${asked.what} for $id started ($started).');
      await _dequeue(id);
    } on UnavailableException catch (error) {
      queued = await _enqueue(asked.withReason(error.message));
    } on ClaimConflictException catch (error) {
      queued = await _enqueue(asked.withReason(error.message));
    }
    await _evaluate();
    return queued;
  });

  /// Drops the queued start of [reference]; false when none waited.
  Future<bool> cancel(String reference) => _serialized(() async {
    final plan = _current ?? await _evaluate(launchAuto: false);
    if (plan == null) throw const NotFoundException('No dispatcher is configured in backlog.yaml.');
    final id = ItemReference.resolve(reference, plan.snapshot.ids);
    final removed = await _dequeue(id);
    if (removed) _log('Dispatcher: the queued start of $id was cancelled.');
    await _evaluate();
    return removed;
  });

  Future<QueuedStart> _enqueue(QueuedStart start) async {
    final state = await _actions.load();
    final index = state.queue.indexWhere((q) => q.item == start.item);
    final queue = [...state.queue];
    if (index < 0) {
      queue.add(start);
    } else {
      queue[index] = start;
    }
    await _actions.save(state.withQueue(queue));
    _log('Dispatcher: queued ${start.what} for ${start.item}: ${start.reason}');
    return start;
  }

  Future<bool> _dequeue(ItemId id) async {
    final state = await _actions.load();
    if (!state.queue.any((q) => q.item == id)) return false;
    await _actions.save(state.withQueue([...state.queue.where((q) => q.item != id)]));
    return true;
  }

  /// Starts [start] with [plan] and describes what started.
  Future<String> _launchStart(DispatchPlan plan, QueuedStart start) async {
    final run = plan.startOf(start);
    if (run.agent case final assignment?) {
      await _launcher.launch(assignment);
      _launched.add(assignment.key);
      if (assignment.action case final action?) await _reviewStarted(assignment.id, action);
      return 'agent ${assignment.agentProfile.name} in ${assignment.agent}'
          '${assignment.resume == null ? '' : ', continuing its session'}';
    }
    final job = run.job!;
    await _launcher.runJob(job);
    return '${job.action.kind == ActionKind.command ? 'command' : 'built-in'} in ${job.worktree ?? job.path}';
  }

  /// Starts the queued starts that can start now, oldest first, in either
  /// mode; returns the plan after the last change (null when nothing
  /// changed) and whether anything started. One that cannot start yet
  /// stays (with the reason); one that can never start any more (the item
  /// done or gone, not ready, …) is dropped with a note.
  Future<(DispatchPlan?, bool)> _runQueue(DispatchPlan plan) async {
    if (plan.queue.isEmpty) return (null, false);
    var current = plan;
    var changed = false;
    var started = false;
    for (final start in plan.queue) {
      String? reason;
      try {
        final what = await _launchStart(current, start);
        _log('Dispatcher: the queued ${start.what} for ${start.item} started ($what).');
        await _dequeue(start.item);
        changed = started = true;
        current = await _plan() ?? current;
        continue;
      } on UnavailableException catch (error) {
        reason = error.message;
      } on ClaimConflictException catch (error) {
        reason = error.message;
      } on BacklogException catch (error) {
        await _dequeue(start.item);
        changed = true;
        await _say(start.item, 'The queued start (${start.what}) was dropped: ${error.message}');
        current = await _plan() ?? current;
        continue;
      }
      if (reason != start.reason) {
        final state = await _actions.load();
        await _actions.save(
          state.withQueue([for (final q in state.queue) q.item == start.item ? q.withReason(reason) : q]),
        );
        changed = true;
      }
    }
    return (changed ? await _plan() ?? current : null, started);
  }

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

  /// A plan of the backlog as it is now. Status changes since the last one
  /// queue the `on_enter` actions (see [ActionState.observe]).
  Future<DispatchPlan?> _plan() async {
    final snapshot = await _snapshot();
    final config = snapshot.workflow.dispatcher;
    if (config == null) return null;
    var conditions = await _launcher.conditions(config, backlogRoot, snapshot);
    final before = await _actions.load();
    final (state, queued) = before.observe(snapshot, config.actions, _clock.now());
    if (queued.isNotEmpty || !_sameStatuses(before.statuses, state.statuses)) await _actions.save(state);
    for (final action in queued) {
      _log('Dispatcher: ${action.item} entered ${action.status}; queued the action "${action.action}".');
    }
    conditions = conditions.withPending(state.pending, queue: state.queue);
    return DispatchPlan.of(snapshot, backlogRoot: backlogRoot, conditions: conditions);
  }

  static bool _sameStatuses(Map<ItemId, String>? a, Map<ItemId, String>? b) =>
      a != null && b != null && const MapEquality<ItemId, String>().equals(a, b);

  Future<DispatchPlan?> _evaluate({bool launchAuto = true}) async {
    if (_closed) return _current;
    DispatchPlan? plan;
    try {
      plan = await _plan();
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
    var launched = false;
    if (launchAuto && plan != null) {
      // Manual mode takes no new work by itself, but replies to an agent
      // (a person's comment, a failed merge) wake it like in auto mode.
      // Replies go first, then the starts people queued, then new work.
      final auto = plan.mode == DispatchMode.auto;
      for (final assignment in plan.assignments) {
        if (plan.isReply(assignment)) launched = await _launch(assignment) || launched;
      }
      var queueWaits = plan.queue.isNotEmpty && launched;
      if (plan.queue.isNotEmpty && !launched) {
        try {
          final (after, started) = await _runQueue(plan);
          if (after != null) {
            if (!after.sameDecisionAs(plan)) _plans.add(after);
            _current = plan = after;
          }
          launched = started;
          queueWaits = started;
        } catch (error, stackTrace) {
          _onError(error, stackTrace);
        }
      }
      if (auto && !queueWaits) {
        for (final assignment in plan!.assignments) {
          if (!plan.isReply(assignment)) launched = await _launch(assignment) || launched;
        }
      }
    }
    if (launchAuto && plan != null) {
      try {
        // After a launch the plan is stale; the launch's change comes back here.
        if (!launched) {
          if (await _runLoops(plan) case final after?) {
            if (!after.sameDecisionAs(plan)) _plans.add(after);
            _current = plan = after;
          }
          if (await _runActions(plan) case final after?) {
            if (!after.sameDecisionAs(plan)) _plans.add(after);
            _current = plan = after;
          }
        }
      } catch (error, stackTrace) {
        _onError(error, stackTrace);
      }
    }
    return plan;
  }

  /// Launches [assignment] unless it was launched already; true when it
  /// started.
  Future<bool> _launch(DispatchAssignment assignment) async {
    if (!_launched.add(assignment.key)) return false;
    try {
      await _launcher.launch(assignment);
      return true;
    } catch (error, stackTrace) {
      _launched.remove(assignment.key);
      _onError(error, stackTrace);
      return false;
    }
  }

  /// Starts the `on_enter` actions that may run now and the actions
  /// requested by `backlog action`, in either mode; returns the plan after
  /// the last start, or null when nothing started.
  ///
  /// A pending action is dropped when its item left the status it entered
  /// (or is gone) or the action is no longer configured, an AI review also
  /// when the latest review saw the head of the item's branch
  /// ([PlannedItem.reviewedHead]); it waits while
  /// anything runs for the item, a prompt action also while the item is
  /// claimed or no worktree is free. Other failures drop it with a note in
  /// the item's discussion, as do failed requests.
  Future<DispatchPlan?> _runActions(DispatchPlan plan) async {
    var current = plan;
    var changed = false;
    // Started or dropped; re-planning after a start may queue new ones.
    final done = <String>{};
    String key(PendingAction action) => '${action.item}|${action.action}|${action.since.toUtc().toIso8601String()}';
    Future<void> forget(PendingAction action) async {
      done.add(key(action));
      changed = true;
      final state = await _actions.load();
      await _actions.save(state.withPending([...state.pending.where((p) => !done.contains(key(p)))]));
    }

    for (final pending in plan.pending) {
      final planned = current.snapshot[pending.item];
      final action = current.config.action(pending.action);
      if (planned == null || action == null || planned.item.status != pending.status) {
        _log(
          'Dispatcher: dropped the action "${pending.action}" for ${pending.item}: '
          '${planned == null
              ? 'the item is gone'
              : action == null
              ? 'no such action any more'
              : 'it left ${pending.status}'}.',
        );
        await forget(pending);
        continue;
      }
      if (current.epicOf(pending.item) case final epic?) {
        _log(
          'Dispatcher: dropped the action "${pending.action}" for ${pending.item}: it belongs to the epic $epic, '
          'which is reviewed and merged as a whole.',
        );
        await forget(pending);
        continue;
      }
      if (current.runFor(pending.item) != null || (action.kind == ActionKind.prompt && planned.isClaimed)) continue;
      if (action.review && planned.reviewedHead) {
        // Back in the status without new commits (e.g. after a failed
        // merge): the review would see the same branch again.
        _log(
          'Dispatcher: skipped the action "${pending.action}" for ${pending.item}: '
          'the latest review already looked at the head of its branch.',
        );
        await forget(pending);
        continue;
      }
      try {
        final started = await _startAction(
          current,
          pending.item.value,
          pending.action,
          ActionTrigger.onEnter,
          from: pending.from,
        );
        _log('Dispatcher: the action "${pending.action}" for ${pending.item} started ($started).');
      } on UnavailableException catch (error) {
        if (action.kind == ActionKind.prompt) continue; // waits for a free worktree
        await _failed(pending.item, pending.action, error.message, 'on entering ${pending.status}');
      } on BacklogException catch (error) {
        await _failed(pending.item, pending.action, error.message, 'on entering ${pending.status}');
      }
      await forget(pending);
      current = await _plan() ?? current;
    }

    for (final request in await _requests?.take() ?? const <ActionRequest>[]) {
      final by = request.by == null ? '' : ' by ${request.by}';
      try {
        final started = await _startAction(current, request.item, request.action, ActionTrigger.request);
        _log('Dispatcher: the action "${request.action}" requested$by for ${request.item} started ($started).');
      } on BacklogException catch (error) {
        if (error is UnavailableException || error is ClaimConflictException) {
          // Not now: it waits in the queue like a button's request.
          try {
            await _enqueue(
              QueuedStart(
                item: ItemReference.resolve(request.item, current.snapshot.ids),
                kind: StartKind.action,
                action: request.action,
                since: request.at,
                by: request.by,
                reason: error.message,
              ),
            );
            changed = true;
            current = await _plan() ?? current;
            continue;
          } on BacklogException {
            // An unknown item: noted below like any failure.
          }
        }
        ItemId? id;
        try {
          id = ItemReference.resolve(request.item, current.snapshot.ids);
        } on BacklogException {
          id = null;
        }
        if (id == null) {
          _log('Dispatcher: the action "${request.action}" requested$by for ${request.item} failed: ${error.message}');
        } else {
          await _failed(id, request.action, error.message, 'requested$by');
        }
      }
      changed = true;
      current = await _plan() ?? current;
    }
    return changed ? await _plan() ?? current : null;
  }

  /// Moves the review ↔ fix loops of AI reviews with `auto_fix` on, in
  /// either mode (see [ReviewLoop]); returns the plan after a change, or
  /// null when nothing happened.
  ///
  /// Nothing happens while anything runs or is queued for the item. After a
  /// review: `ok` (or no verdict at all) ends the loop; `changes` wakes the
  /// item's agent to fix them ([DispatchPlan.fixStart], waiting for a free
  /// worktree), unless `auto_fix` rounds ran already — then the loop is
  /// exhausted and a person decides. After a fix: new commits on the
  /// branch (the review is `stale`) queue the review again; none end the
  /// loop.
  Future<DispatchPlan?> _runLoops(DispatchPlan plan) async {
    final state = await _actions.load();
    if (state.loops.isEmpty) return null;
    final loops = {...state.loops};
    final queued = <PendingAction>[];
    var changed = false;
    var current = plan;
    final now = _clock.now();
    for (final MapEntry(key: id, value: loop) in state.loops.entries) {
      final planned = current.snapshot[id];
      final action = current.config.action(loop.action);
      if (planned == null || planned.isDone || action == null || !action.review || action.autoFix == 0) {
        loops.remove(id);
        changed = true;
        continue;
      }
      if (loop.phase == ReviewLoopPhase.exhausted) continue;
      if (current.runFor(id) != null || current.pending.any((p) => p.item == id)) continue;
      final rounds = action.autoFix;
      if (loop.phase == ReviewLoopPhase.fixing) {
        changed = true;
        if (planned.review == ReviewState.stale) {
          queued.add(PendingAction(item: id, action: action.name, status: planned.item.status, since: now.toUtc()));
          loops[id] = loop.to(ReviewLoopPhase.reviewing, now);
          _log('Dispatcher: $id has new commits after the fix; queued the action "${action.name}" again.');
        } else {
          loops.remove(id);
          await _say(
            id,
            'The agent ended the fix round ${loop.round} of the AI review without new commits; '
            'the automatic fixes stop here.',
          );
        }
        continue;
      }
      // Reviewing, and the review has ended.
      final review = planned.item.discussion.lastReview;
      final since = DateTime.fromMillisecondsSinceEpoch(
        loop.since.millisecondsSinceEpoch ~/ 1000 * 1000,
        isUtc: true,
      ); // comments have seconds
      if (review == null || review.at.isBefore(since) || review.review == ReviewVerdict.ok) {
        loops.remove(id);
        changed = true;
        _log(
          'Dispatcher: the review loop of $id ends: '
          '${review == null || review.at.isBefore(since) ? 'the review gave no verdict' : 'the review is ok'}.',
        );
        continue;
      }
      if (loop.round >= rounds) {
        loops[id] = loop.to(ReviewLoopPhase.exhausted, now);
        changed = true;
        await _say(
          id,
          'The AI review still asks for changes after $rounds automatic fix round${rounds == 1 ? '' : 's'} '
          '(auto_fix: $rounds); a person decides now.',
        );
        continue;
      }
      final DispatchAssignment assignment;
      try {
        assignment = current.fixStart(id, review: review, round: loop.round + 1, rounds: rounds);
        await _launcher.launch(assignment);
      } on UnavailableException {
        continue; // waits for a free worktree
      } on ClaimConflictException {
        continue; // waits until the claim is gone
      } on BacklogException catch (error) {
        loops.remove(id);
        changed = true;
        await _say(id, 'Could not wake the agent to fix the findings of the AI review: ${error.message}');
        continue;
      }
      _launched.add(assignment.key);
      loops[id] = loop.to(ReviewLoopPhase.fixing, _clock.now(), round: loop.round + 1);
      changed = true;
      _log(
        'Dispatcher: the AI review of $id asks for changes; started its agent in ${assignment.agent} to fix them '
        '(round ${loop.round + 1} of $rounds${assignment.resume == null ? '' : ', continuing its session'}).',
      );
      await _say(
        id,
        'The AI review asks for changes: started the agent in ${assignment.agent} to fix them '
        '(automatic round ${loop.round + 1} of $rounds).',
      );
      current = await _plan() ?? current;
    }
    if (!changed) return null;
    final latest = await _actions.load();
    await _actions.save(
      latest
          .withPending([
            ...latest.pending,
            for (final action in queued)
              if (!latest.pending.any((p) => p.item == action.item && p.action == action.action)) action,
          ])
          .withLoops(loops),
    );
    return await _plan() ?? current;
  }

  /// Starts or continues the review loop of [item] when the review [action]
  /// with `auto_fix` starts for it: a loop in progress keeps its rounds, a
  /// new one (or after an exhausted one) starts from zero.
  Future<void> _reviewStarted(ItemId item, ActionDefinition action) async {
    if (!action.review || action.autoFix == 0) return;
    final state = await _actions.load();
    final existing = state.loops[item];
    final round = existing == null || existing.phase == ReviewLoopPhase.exhausted ? 0 : existing.round;
    await _actions.save(
      state.withLoops({
        ...state.loops,
        item: ReviewLoop(
          item: item,
          action: action.name,
          round: round,
          phase: ReviewLoopPhase.reviewing,
          since: _clock.now(),
        ),
      }),
    );
  }

  /// A note on [item] by the dispatcher, and the same in the log.
  Future<void> _say(ItemId item, String text) async {
    _log('Dispatcher: $item: $text');
    try {
      await _note?.call(item, text);
    } on BacklogException catch (error) {
      _log('Dispatcher: could not add a note to $item: ${error.message}');
    }
  }

  Future<void> _failed(ItemId item, String action, String message, String why) async {
    _log('Dispatcher: the action "$action" for $item ($why) could not start: $message');
    try {
      await _note?.call(item, 'The action "$action" ($why) could not start: $message');
    } on BacklogException catch (error) {
      _log('Dispatcher: could not add a note to $item: ${error.message}');
    }
  }

  /// Starts [name] on [reference] with [plan] and describes what started.
  Future<String> _startAction(
    DispatchPlan plan,
    String reference,
    String name,
    ActionTrigger trigger, {
    String? from,
  }) async {
    final start = plan.actionStart(reference, name, trigger: trigger, from: from);
    if (start.agent case final assignment?) {
      await _launcher.launch(assignment);
      _launched.add(assignment.key);
      await _reviewStarted(assignment.id, assignment.action!);
      return 'agent ${assignment.agentProfile.name} in ${assignment.agent}'
          '${assignment.resume == null ? '' : ', continuing its session'}';
    }
    final job = start.job!;
    await _launcher.runJob(job);
    return '${job.action.kind == ActionKind.command ? 'command' : 'built-in'} in ${job.worktree ?? job.path}';
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
