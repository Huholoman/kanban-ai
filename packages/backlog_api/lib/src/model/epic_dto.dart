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
  });

  factory EpicMemberDto.fromJson(Json json) => EpicMemberDto(
    id: json.string('id'),
    title: json.string('title'),
    status: json.string('status'),
    state: json.string('state'),
    after: json.strings('after'),
    waits: json.strings('waits'),
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

  bool get isSettled => state == 'done' || state == 'handed-over';

  Json toJson() => {'id': id, 'title': title, 'status': status, 'state': state, 'after': after, 'waits': waits};
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

  bool get isForbidden => verdict == 'forbidden';

  bool get hasWarnings => verdict == 'warning';

  /// How many members are in [state].
  int count(String state) => members.where((m) => m.state == state).length;

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
  };
}
