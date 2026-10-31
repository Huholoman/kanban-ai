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
  const PendingAction({required this.item, required this.action, required this.status, required this.since});

  factory PendingAction.fromJson(Map<String, Object?> json) => PendingAction(
    item: ItemId(json['item']! as String),
    action: json['action']! as String,
    status: json['status']! as String,
    since: DateTime.parse(json['since']! as String),
  );

  final ItemId item;

  /// The name of the action.
  final String action;
  final String status;
  final DateTime since;

  Map<String, Object?> toJson() => {
    'item': item.value,
    'action': action,
    'status': status,
    'since': since.toUtc().toIso8601String(),
  };
}

/// What the dispatcher remembers about status hooks between evaluations
/// and restarts: the status each item had when it was last looked at, and
/// the `on_enter` actions still waiting to run.
final class ActionState {
  const ActionState({this.statuses, this.pending = const []});

  /// Item → status at the last evaluation; null before the first one.
  final Map<ItemId, String>? statuses;
  final List<PendingAction> pending;

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
            queued.add(PendingAction(item: planned.id, action: action.name, status: status, since: now.toUtc()));
          }
        }
      }
    }
    final kept = [
      for (final waiting in pending)
        if (!queued.any((q) => q.item == waiting.item && q.action == waiting.action)) waiting,
    ];
    return (ActionState(statuses: after, pending: [...kept, ...queued]), queued);
  }

  ActionState withPending(List<PendingAction> pending) => ActionState(statuses: statuses, pending: pending);

  Map<String, Object?> toJson() => {
    'statuses': {for (final MapEntry(:key, :value) in (statuses ?? const {}).entries) key.value: value},
    'pending': [for (final action in pending) action.toJson()],
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
  });

  final PlannedItem item;
  final ActionDefinition action;
  final ActionTrigger trigger;

  /// The dispatcher worktree it runs in (busy meanwhile); null in the
  /// primary clone.
  final String? worktree;

  /// Absolute working directory.
  final String path;

  /// The placeholders ([ActionDefinition.commandPlaceholders]) filled in.
  final Map<String, String> values;

  /// The rendered command; null for a built-in action.
  final List<String>? command;

  /// Added to the server's environment.
  final Map<String, String> environment;

  ItemId get id => item.id;
}
