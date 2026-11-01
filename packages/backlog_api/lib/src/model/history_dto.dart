import 'json.dart';

/// One entry of an item's history (`GET /api/items/<ref>/history`, shaped
/// like `backlog --json history`): who did what when.
final class HistoryEntryDto {
  const HistoryEntryDto({
    required this.kind,
    required this.at,
    this.author,
    this.field,
    this.before,
    this.after,
    this.text,
    this.tag,
    this.commit,
    this.uncommitted = false,
    this.log,
  });

  factory HistoryEntryDto.fromJson(Json json) => HistoryEntryDto(
    kind: json.string('kind'),
    at: DateTime.parse(json.string('at')),
    author: json.optionalString('author'),
    field: json.optionalString('field'),
    before: json.optionalString('before'),
    after: json.optionalString('after'),
    text: json.optionalString('text'),
    tag: json.optionalString('tag'),
    commit: json.optionalString('commit'),
    uncommitted: json.boolean('uncommitted'),
    log: json.optionalString('log'),
  );

  /// `created`, `field`, `body` (the description changed), `comment` or `run`.
  final String kind;
  final DateTime at;
  final String? author;

  /// The changed field of a `field` entry (`checklist`: its progress).
  final String? field;
  final String? before;
  final String? after;

  /// A comment's text; for a run what ran and how it ended.
  final String? text;

  /// `question`, `note`, `review ok`, `review changes` for comments; the
  /// action of a run of an action.
  final String? tag;

  /// The commit of the backlog repository with the change.
  final String? commit;

  /// The change is in the file but not committed yet.
  final bool uncommitted;

  /// The log file of a run.
  final String? log;

  Json toJson() => {
    'kind': kind,
    'at': at.toUtc().toIso8601String(),
    'author': author,
    'field': field,
    'before': before,
    'after': after,
    'text': text,
    'tag': tag,
    'commit': commit,
    'uncommitted': uncommitted,
    'log': log,
  };
}
