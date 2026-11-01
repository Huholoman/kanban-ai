import 'json.dart';

/// An item under an epic and where it stands in the epic's implementation.
final class EpicMemberDto {
  const EpicMemberDto({
    required this.id,
    required this.title,
    required this.status,
    required this.state,
    this.after = const [],
    this.waits = const [],
    this.milestone,
    this.inScope = true,
  });

  factory EpicMemberDto.fromJson(Json json) => EpicMemberDto(
    id: json.string('id'),
    title: json.string('title'),
    status: json.string('status'),
    state: json.string('state'),
    after: json.strings('after'),
    waits: json.strings('waits'),
    milestone: json.optionalString('milestone'),
    inScope: json.boolean('in_scope', fallback: true),
  );

  final String id;
  final String title;
  final String status;

  /// `done`, `handed-over` (e.g. in review), `in-progress` or `to-do`.
  final String state;

  /// Items of the epic it comes after that are not done or handed over yet.
  final List<String> after;

  /// What outside the epic keeps it from starting.
  final List<String> waits;

  final String? milestone;

  /// It belongs to the run's milestone ([EpicDto.milestone]).
  final bool inScope;

  bool get isSettled => state == 'done' || state == 'handed-over';

  Json toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'state': state,
    'after': after,
    'waits': waits,
    'milestone': milestone,
    'in_scope': inScope,
  };
}

/// How far the items of an epic in one milestone are.
final class EpicProgressDto {
  const EpicProgressDto({required this.milestone, required this.settled, required this.total});

  factory EpicProgressDto.fromJson(Json json) => EpicProgressDto(
    milestone: json.optionalString('milestone'),
    settled: json.integer('settled'),
    total: json.integer('total'),
  );

  /// Null for the items without a milestone.
  final String? milestone;

  /// Handed over or done.
  final int settled;
  final int total;

  bool get finished => settled == total;

  Json toJson() => {'milestone': milestone, 'settled': settled, 'total': total};
}

/// Whether one agent can implement an epic on one branch, and how far it is
/// (`GET /api/items/<ref>/epic`).
final class EpicDto {
  const EpicDto({
    required this.epic,
    required this.title,
    required this.branch,
    required this.verdict,
    this.problems = const [],
    this.warnings = const [],
    this.finished = false,
    this.next,
    this.members = const [],
    this.milestone,
    this.skipped = const [],
    this.progress = const [],
  });

  factory EpicDto.fromJson(Json json) => EpicDto(
    epic: json.string('epic'),
    title: json.string('title'),
    branch: json.string('branch'),
    verdict: json.string('verdict'),
    problems: json.strings('problems'),
    warnings: json.strings('warnings'),
    finished: json.boolean('finished'),
    next: json.optionalString('next'),
    members: json.objects('members').map(EpicMemberDto.fromJson).toList(),
    milestone: json.optionalString('milestone'),
    skipped: json.strings('skipped'),
    progress: json.objects('progress').map(EpicProgressDto.fromJson).toList(),
  );

  final String epic;
  final String title;

  /// The branch all of it is implemented on.
  final String branch;

  /// `ok`, `warning` (start with a confirmation) or `forbidden` ([problems]).
  final String verdict;
  final List<String> problems;
  final List<String> warnings;

  /// Every item is handed over or done.
  final bool finished;

  /// The item the agent takes next, if any.
  final String? next;

  /// The items under the epic in the order they can be done.
  final List<EpicMemberDto> members;

  /// The milestone the run is limited to (with the items without one); null
  /// for all of the epic.
  final String? milestone;

  /// Unsettled items outside [milestone] that the run leaves as they are.
  final List<String> skipped;

  /// How far the items are per milestone, whatever the scope.
  final List<EpicProgressDto> progress;

  bool get isForbidden => verdict == 'forbidden';

  bool get hasWarnings => verdict == 'warning';

  /// How many members (in the scope) are in [state].
  int count(String state) => members.where((m) => m.inScope && m.state == state).length;

  Json toJson() => {
    'epic': epic,
    'title': title,
    'branch': branch,
    'verdict': verdict,
    'problems': problems,
    'warnings': warnings,
    'finished': finished,
    'next': next,
    'members': [for (final member in members) member.toJson()],
    'milestone': milestone,
    'skipped': skipped,
    'progress': [for (final entry in progress) entry.toJson()],
  };
}
