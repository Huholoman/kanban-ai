import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
import '../../workflow/domain/action_definition.dart';
import 'dispatch_plan.dart';

/// What a running process of the dispatcher is.
enum RunKind {
  /// An agent: the dispatcher's own or one started by a prompt action.
  agent,

  /// The command of an action (`run: [...]`).
  command,

  /// A built-in action (`run: <name>`), run inside the server.
  builtIn;

  /// The name in records and the API (`agent`, `command`, `builtin`).
  String get id => this == builtIn ? 'builtin' : name;

  static RunKind parse(Object? value) => values.firstWhere((kind) => kind.id == value, orElse: () => agent);
}

/// Why an action runs.
enum ActionTrigger {
  /// A person: a button on the board, the API or `backlog action`.
  request('request'),

  /// The item entered the action's `on_enter` status.
  onEnter('on_enter');

  const ActionTrigger(this.id);

  final String id;
}

/// An `on_enter` action waiting to run: [item] entered [status] at [since]
/// and the action runs as soon as nothing else runs for the item (and, for
/// a prompt action, a worktree is free). It is dropped when the item leaves
/// [status] first or the action is no longer configured.
final class PendingAction {
  const PendingAction({required this.item, required this.action, required this.status, required this.since, this.from});

  factory PendingAction.fromJson(Map<String, Object?> json) => PendingAction(
    item: ItemId(json['item']! as String),
    action: json['action']! as String,
    status: json['status']! as String,
    since: DateTime.parse(json['since']! as String),
    from: json['from'] as String?,
  );

  final ItemId item;

  /// The name of the action.
  final String action;
  final String status;
  final DateTime since;

  /// The status the item came from (e.g. `review` for an item moved to
  /// `deploy`); null in state written by older versions.
  final String? from;

  Map<String, Object?> toJson() => {
    'item': item.value,
    'action': action,
    'status': status,
    'since': since.toUtc().toIso8601String(),
    'from': ?from,
  };
}

/// What a person asked to start ([QueuedStart.kind]).
enum StartKind {
  /// The item's own agent (*Start agent*, `dispatch/start`).
  agent,

  /// One agent implementing the item as an epic (*Implement epic*,
  /// `dispatch/epic`).
  epic,

  /// An action (`…/actions/<name>`, `backlog action`).
  action;

  static StartKind parse(Object? value) => values.firstWhere((k) => k.name == value, orElse: () => agent);
}

/// A start a person asked for that could not happen at once (no free
/// worktree, `max_agents` reached, the branch busy in another worktree,
/// something already running for the item): the dispatcher starts it as
/// soon as it can, in the order of the queue. At most one per item.
final class QueuedStart {
  const QueuedStart({
    required this.item,
    required this.kind,
    required this.since,
    this.action,
    this.fresh = false,
    this.by,
    this.reason,
  });

  factory QueuedStart.fromJson(Map<String, Object?> json) => QueuedStart(
    item: ItemId(json['item']! as String),
    kind: StartKind.parse(json['kind']),
    since: DateTime.parse(json['since']! as String),
    action: json['action'] as String?,
    fresh: json['fresh'] == true,
    by: json['by'] as String?,
    reason: json['reason'] as String?,
  );

  final ItemId item;
  final StartKind kind;
  final DateTime since;

  /// The action's name for [StartKind.action].
  final String? action;

  /// A new session instead of the item's last one (agent and epic).
  final bool fresh;

  /// Who asked, when known.
  final String? by;

  /// Why the last attempt could not start it.
  final String? reason;

  /// `Start agent`, `Implement epic`, `the action "AI review"`.
  String get what => switch (kind) {
    StartKind.agent => fresh ? 'Start fresh' : 'Start agent',
    StartKind.epic => 'Implement epic',
    StartKind.action => 'the action "$action"',
  };

  QueuedStart withReason(String reason) =>
      QueuedStart(item: item, kind: kind, since: since, action: action, fresh: fresh, by: by, reason: reason);

  Map<String, Object?> toJson() => {
    'item': item.value,
    'kind': kind.name,
    'since': since.toUtc().toIso8601String(),
    'action': ?action,
    if (fresh) 'fresh': true,
    'by': ?by,
    'reason': ?reason,
  };
}

/// Where the review ↔ fix loop of an AI review with `auto_fix` stands.
enum ReviewLoopPhase {
  /// The review runs or is queued; its verdict decides what follows.
  reviewing,

  /// The item's agent fixes the findings; once it has ended, new commits
  /// queue the review again.
  fixing,

  /// The review still asks for changes after `auto_fix` rounds; a person
  /// decides (a review started later begins a new loop).
  exhausted;

  static ReviewLoopPhase parse(Object? value) => values.firstWhere((p) => p.name == value, orElse: () => exhausted);
}

/// The review ↔ fix loop of [item] with the review action [action]: how
/// many fix rounds ran ([round]), and since when the current [phase] holds.
final class ReviewLoop {
  const ReviewLoop({
    required this.item,
    required this.action,
    required this.round,
    required this.phase,
    required this.since,
  });

  factory ReviewLoop.fromJson(Map<String, Object?> json) => ReviewLoop(
    item: ItemId(json['item']! as String),
    action: json['action']! as String,
    round: json['round'] as int? ?? 0,
    phase: ReviewLoopPhase.parse(json['phase']),
    since: DateTime.parse(json['since']! as String),
  );

  final ItemId item;
  final String action;

  /// Fix rounds started so far.
  final int round;
  final ReviewLoopPhase phase;
  final DateTime since;

  ReviewLoop to(ReviewLoopPhase phase, DateTime since, {int? round}) =>
      ReviewLoop(item: item, action: action, round: round ?? this.round, phase: phase, since: since);

  Map<String, Object?> toJson() => {
    'item': item.value,
    'action': action,
    'round': round,
    'phase': phase.name,
    'since': since.toUtc().toIso8601String(),
  };
}

/// What the dispatcher remembers about status hooks between evaluations
/// and restarts: the status each item had when it was last looked at, the
/// `on_enter` actions still waiting to run, the review ↔ fix loops of
/// AI reviews with `auto_fix` and the queue of starts people asked for.
final class ActionState {
  const ActionState({this.statuses, this.pending = const [], this.loops = const {}, this.queue = const []});

  /// Item → status at the last evaluation; null before the first one.
  final Map<ItemId, String>? statuses;
  final List<PendingAction> pending;
  final Map<ItemId, ReviewLoop> loops;

  /// Starts people asked for that wait, oldest first.
  final List<QueuedStart> queue;

  /// Compares [snapshot] with [statuses]: every item whose status changed
  /// to the `on_enter` status of an action gets that action queued (once
  /// per transition, in the configured order). Items seen for the first
  /// time (new items, the very first evaluation) trigger nothing. Returns
  /// the new state and the newly queued actions.
  (ActionState, List<PendingAction>) observe(BacklogSnapshot snapshot, List<ActionDefinition> actions, DateTime now) {
    final before = statuses;
    final after = {for (final planned in snapshot.items) planned.id: planned.item.status};
    final queued = <PendingAction>[];
    if (before != null) {
      for (final planned in snapshot.items) {
        final previous = before[planned.id];
        final status = planned.item.status;
        if (previous == null || previous == status) continue;
        for (final action in actions) {
          if (action.onEnter == status) {
            queued.add(
              PendingAction(item: planned.id, action: action.name, status: status, since: now.toUtc(), from: previous),
            );
          }
        }
      }
    }
    final kept = [
      for (final waiting in pending)
        if (!queued.any((q) => q.item == waiting.item && q.action == waiting.action)) waiting,
    ];
    return (ActionState(statuses: after, pending: [...kept, ...queued], loops: loops, queue: queue), queued);
  }

  ActionState withPending(List<PendingAction> pending) =>
      ActionState(statuses: statuses, pending: pending, loops: loops, queue: queue);

  ActionState withLoops(Map<ItemId, ReviewLoop> loops) =>
      ActionState(statuses: statuses, pending: pending, loops: loops, queue: queue);

  ActionState withQueue(List<QueuedStart> queue) =>
      ActionState(statuses: statuses, pending: pending, loops: loops, queue: queue);

  Map<String, Object?> toJson() => {
    'statuses': {for (final MapEntry(:key, :value) in (statuses ?? const {}).entries) key.value: value},
    'pending': [for (final action in pending) action.toJson()],
    'loops': [for (final loop in loops.values) loop.toJson()],
    'queue': [for (final start in queue) start.toJson()],
  };

  factory ActionState.fromJson(Map<String, Object?> json) => ActionState(
    statuses: switch (json['statuses']) {
      final Map<Object?, Object?> map => {for (final MapEntry(:key, :value) in map.entries) ItemId('$key'): '$value'},
      _ => null,
    },
    pending: [
      for (final entry in (json['pending'] as List<Object?>? ?? const []))
        PendingAction.fromJson((entry! as Map).cast<String, Object?>()),
    ],
    loops: {
      for (final entry in (json['loops'] as List<Object?>? ?? const []))
        if (ReviewLoop.fromJson((entry! as Map).cast<String, Object?>()) case final loop) loop.item: loop,
    },
    queue: [
      for (final entry in (json['queue'] as List<Object?>? ?? const []))
        QueuedStart.fromJson((entry! as Map).cast<String, Object?>()),
    ],
  );
}

/// Port: where [ActionState] is kept (a file in the state folder, so that
/// a restarted server neither repeats nor forgets status hooks).
abstract interface class ActionStateStore {
  Future<ActionState> load();
  Future<void> save(ActionState state);
}

/// An [ActionStateStore] in memory; the state is lost with the process.
final class MemoryActionStateStore implements ActionStateStore {
  ActionState _state = const ActionState();

  @override
  Future<ActionState> load() async => _state;

  @override
  Future<void> save(ActionState state) async => _state = state;
}

/// A request to run an action, written by `backlog action` (which has no
/// dispatcher of its own) for the server to pick up.
final class ActionRequest {
  const ActionRequest({required this.item, required this.action, required this.at, this.by});

  factory ActionRequest.fromJson(Map<String, Object?> json) => ActionRequest(
    item: json['item']! as String,
    action: json['action']! as String,
    at: DateTime.parse(json['at']! as String),
    by: json['by'] as String?,
  );

  /// The item as written (a reference).
  final String item;
  final String action;
  final DateTime at;

  /// Who asked (`BACKLOG_AGENT`, `$USER`), when known.
  final String? by;

  Map<String, Object?> toJson() => {'item': item, 'action': action, 'at': at.toUtc().toIso8601String(), 'by': by};
}

/// Port: requests to run actions that wait for the server.
abstract interface class ActionRequests {
  Future<void> add(ActionRequest request);

  /// Takes the waiting requests, oldest first; each is returned once.
  Future<List<ActionRequest>> take();
}

/// A command or built-in action ready to run for [item]: in [path] (the
/// item's worktree [worktree], or the primary clone when [worktree] is
/// null). Prompt actions are [DispatchAssignment]s instead.
final class ActionJob {
  const ActionJob({
    required this.item,
    required this.action,
    required this.trigger,
    required this.path,
    required this.values,
    this.worktree,
    this.command,
    this.environment = const {},
    this.from,
  });

  final PlannedItem item;
  final ActionDefinition action;
  final ActionTrigger trigger;

  /// For a hook: the status the item was in before it entered the
  /// action's `on_enter` status (where a failed merge sends it back).
  final String? from;

  /// The dispatcher worktree it runs in (busy meanwhile); null in the
  /// primary clone.
  final String? worktree;

  /// Absolute working directory.
  final String path;

  /// The placeholders ([ActionDefinition.commandPlaceholders]) filled in.
  final Map<String, String> values;

  /// The rendered command; null for a built-in action.
  final List<String>? command;

  /// Added to the server's environment: `DispatchAssignment.headlessGit`,
  /// `BACKLOG_DIR`, `KANBAN_AI_ITEM`, `KANBAN_AI_ACTION` and, in a worktree,
  /// `BACKLOG_AGENT`.
  final Map<String, String> environment;

  ItemId get id => item.id;
}
