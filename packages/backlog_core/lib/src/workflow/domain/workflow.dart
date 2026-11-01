import '../../shared/errors.dart';
import 'action_definition.dart';
import 'appearance.dart';
import 'dispatcher_config.dart';

/// What a status means for planning, independently of its name.
enum StatusCategory {
  /// Not started (backlog, todo, …).
  open,

  /// Somebody works on it (in-progress, review, …).
  active,

  /// Finished or dropped; satisfies dependencies.
  done;

  static StatusCategory parse(String value) => StatusCategory.values.firstWhere(
    (category) => category.name == value,
    orElse: () => throw ConfigurationException('Unknown status category "$value" (expected open, active or done).'),
  );
}

final class StatusDefinition {
  const StatusDefinition(this.id, this.category, {this.pickable = false});

  final String id;
  final StatusCategory category;

  /// Agents may pick items in this status up as ready work.
  final bool pickable;
}

final class MilestoneDefinition {
  const MilestoneDefinition(this.id, {this.title, this.due});

  final String id;
  final String? title;
  final String? due;
}

/// The rules of one backlog: which statuses, priorities, types and milestones
/// exist and how new items and claims behave. Loaded from `backlog.yaml`.
final class Workflow {
  factory Workflow({
    required List<StatusDefinition> statuses,
    required List<String> priorities,
    required List<String> types,
    List<MilestoneDefinition> milestones = const [],
    String idPrefix = 'T',
    int idLength = 4,
    String? defaultStatus,
    String? defaultPriority,
    String? defaultType,
    Duration claimLease = const Duration(hours: 4),
    Appearance appearance = Appearance.none,
    DispatcherConfig? dispatcher,
    BacklogGit git = BacklogGit.standard,
    bool persistentItemCache = false,
  }) {
    _require(statuses.isNotEmpty, 'At least one status is required.');
    _requireUnique(statuses.map((s) => s.id), 'status');
    _require(
      statuses.any((s) => s.category == StatusCategory.active),
      'At least one status must have category "active".',
    );
    _require(statuses.any((s) => s.category == StatusCategory.done), 'At least one status must have category "done".');
    _require(
      statuses.any((s) => s.pickable && s.category == StatusCategory.open),
      'At least one "open" status must be pickable.',
    );
    _require(priorities.isNotEmpty, 'At least one priority is required.');
    _requireUnique(priorities, 'priority');
    _require(types.isNotEmpty, 'At least one item type is required.');
    _requireUnique(types, 'type');
    _requireUnique(milestones.map((m) => m.id), 'milestone');
    _require(
      RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(idPrefix),
      'ID prefix "$idPrefix" must be alphanumeric and start with a letter.',
    );
    _require(idLength >= 3 && idLength <= 12, 'ID length must be between 3 and 12.');
    _require(!claimLease.isNegative && claimLease != Duration.zero, 'Claim lease must be positive.');

    final status = defaultStatus ?? statuses.first.id;
    final priority = defaultPriority ?? priorities[priorities.length ~/ 2];
    final type = defaultType ?? types.first;
    _require(statuses.any((s) => s.id == status), 'Default status "$status" is not defined.');
    _require(priorities.contains(priority), 'Default priority "$priority" is not defined.');
    _require(types.contains(type), 'Default type "$type" is not defined.');
    for (final action in dispatcher?.actions ?? const <ActionDefinition>[]) {
      for (final listed in [?action.onEnter, ?action.then, ...?action.statuses]) {
        _require(statuses.any((s) => s.id == listed), 'dispatcher.actions "${action.name}": unknown status "$listed".');
      }
    }

    return Workflow._(
      statuses: List.unmodifiable(statuses),
      priorities: List.unmodifiable(priorities),
      types: List.unmodifiable(types),
      milestones: List.unmodifiable(milestones),
      idPrefix: idPrefix,
      idLength: idLength,
      defaultStatus: status,
      defaultPriority: priority,
      defaultType: type,
      claimLease: claimLease,
      appearance: appearance,
      dispatcher: dispatcher,
      git: git,
      persistentItemCache: persistentItemCache,
    );
  }

  Workflow._({
    required this.statuses,
    required this.priorities,
    required this.types,
    required this.milestones,
    required this.idPrefix,
    required this.idLength,
    required this.defaultStatus,
    required this.defaultPriority,
    required this.defaultType,
    required this.claimLease,
    required this.appearance,
    required this.dispatcher,
    required this.git,
    required this.persistentItemCache,
  });

  /// The workflow `backlog init` writes out.
  factory Workflow.standard() => Workflow(
    statuses: const [
      StatusDefinition('backlog', StatusCategory.open),
      StatusDefinition('todo', StatusCategory.open, pickable: true),
      StatusDefinition('in-progress', StatusCategory.active),
      StatusDefinition('review', StatusCategory.active),
      StatusDefinition('done', StatusCategory.done),
      StatusDefinition('cancelled', StatusCategory.done),
    ],
    priorities: const ['p0', 'p1', 'p2', 'p3'],
    types: const ['task', 'story', 'epic', 'bug', 'decision', 'idea'],
    defaultStatus: 'backlog',
    defaultPriority: 'p2',
    defaultType: 'task',
  );

  /// Ordered as they appear on a board.
  final List<StatusDefinition> statuses;

  /// Ordered from the most urgent.
  final List<String> priorities;
  final List<String> types;
  final List<MilestoneDefinition> milestones;
  final String idPrefix;
  final int idLength;
  final String defaultStatus;
  final String defaultPriority;
  final String defaultType;

  /// How long a claim stays valid without a heartbeat.
  final Duration claimLease;

  /// Colours and default mode of the web board.
  final Appearance appearance;

  /// Who starts agents on ready work; null when `backlog.yaml` has no
  /// `dispatcher` section (the dispatcher is off).
  final DispatcherConfig? dispatcher;

  /// How the server keeps the backlog's own git repository (`git`).
  final BacklogGit git;

  /// Keep parsed item files in the backlog's `.cache/` between processes
  /// (`cache.items`), so that the CLI starts faster on big backlogs.
  final bool persistentItemCache;

  StatusDefinition? status(String id) {
    for (final status in statuses) {
      if (status.id == id) return status;
    }
    return null;
  }

  StatusCategory? categoryOf(String statusId) => status(statusId)?.category;

  bool hasPriority(String id) => priorities.contains(id);

  bool hasType(String id) => types.contains(id);

  /// Milestones are free-form until `backlog.yaml` lists some.
  bool acceptsMilestone(String id) => milestones.isEmpty || milestones.any((m) => m.id == id);

  /// Unknown values sort after every known one.
  int statusRank(String id) {
    final index = statuses.indexWhere((s) => s.id == id);
    return index < 0 ? statuses.length : index;
  }

  /// Where milestone [id] comes in the order of ready work: the position in
  /// [milestones]; no milestone, `later` (the parking lot) and unknown ids
  /// after all of them. Always 0 without milestones.
  int milestoneRank(String? id) {
    if (id == null || id == 'later') return milestones.length;
    final index = milestones.indexWhere((m) => m.id == id);
    return index < 0 ? milestones.length : index;
  }

  int priorityRank(String id) {
    final index = priorities.indexOf(id);
    return index < 0 ? priorities.length : index;
  }

  /// Status an item gets when an agent claims it.
  String get activeStatus => statuses.firstWhere((s) => s.category == StatusCategory.active).id;

  /// Status `done` moves an item to.
  String get doneStatus => statuses.firstWhere((s) => s.category == StatusCategory.done).id;

  /// Status a released, unfinished item returns to.
  String get pickableStatus => statuses.firstWhere((s) => s.pickable && s.category == StatusCategory.open).id;

  static void _require(bool condition, String message) {
    if (!condition) throw ConfigurationException(message);
  }

  static void _requireUnique(Iterable<String> values, String what) {
    final seen = <String>{};
    for (final value in values) {
      if (!seen.add(value)) {
        throw ConfigurationException('Duplicate $what "$value".');
      }
    }
  }
}

/// When the server commits the changes in the backlog folder (`git.commit`).
enum BacklogCommitMode {
  /// When the backlog folder is a git repository of its own (its top level),
  /// after agents' runs and a short quiet period.
  auto,

  /// Never; people commit it.
  off;

  static BacklogCommitMode parse(String value) => values.firstWhere(
    (m) => m.name == value,
    orElse: () => throw ArgumentError('git.commit must be ${values.map((m) => m.name).join(' or ')}, not "$value".'),
  );
}

/// How the server keeps the backlog's own git repository (`git` in
/// `backlog.yaml`): agents change items through the CLI from their
/// worktrees, but never commit the backlog; the server does.
final class BacklogGit {
  const BacklogGit({this.commit = BacklogCommitMode.auto, this.push = false});

  static const standard = BacklogGit();

  final BacklogCommitMode commit;

  /// Push after each commit (`git push`, to the branch's upstream).
  final bool push;
}
