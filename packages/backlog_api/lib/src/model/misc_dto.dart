import 'json.dart';

final class LintIssueDto {
  const LintIssueDto({required this.severity, required this.code, required this.message, this.item, this.location});

  factory LintIssueDto.fromJson(Json json) => LintIssueDto(
    severity: json.string('severity'),
    code: json.string('code'),
    message: json.string('message'),
    item: json.optionalString('item'),
    location: json.optionalString('location'),
  );

  /// `error` or `warning`.
  final String severity;
  final String code;
  final String message;
  final String? item;
  final String? location;

  bool get isError => severity == 'error';

  Json toJson() => {'severity': severity, 'code': code, 'message': message, 'item': item, 'location': location};
}

/// Something in the backlog folder changed — items, views or configuration
/// (`type: changed`) — or the dispatcher's plan changed (`type: dispatch`,
/// no paths). Clients reload what they show.
final class BacklogChangeEvent {
  const BacklogChangeEvent(this.paths, {this.type = 'changed'});

  /// The dispatcher's plan changed (agents started or ended, worktrees …).
  const BacklogChangeEvent.dispatch() : paths = const [], type = 'dispatch';

  factory BacklogChangeEvent.fromJson(Json json) =>
      BacklogChangeEvent(json.strings('paths'), type: json.optionalString('type') ?? 'changed');

  /// Changed files relative to the backlog root.
  final List<String> paths;

  /// `changed` or `dispatch`.
  final String type;

  bool get isDispatch => type == 'dispatch';

  Json toJson() => {'type': type, 'paths': paths};
}

/// An error answered by the server, in the same shape as `backlog --json`.
final class BacklogApiException implements Exception {
  const BacklogApiException(this.statusCode, this.type, this.message, {this.candidates = const []});

  factory BacklogApiException.fromJson(int statusCode, Json json) {
    final error = json.object('error');
    return BacklogApiException(
      statusCode,
      error.string('type'),
      error.string('message'),
      candidates: error.strings('candidates'),
    );
  }

  /// HTTP status; 0 when the server could not be reached.
  final int statusCode;

  /// `not_found`, `ambiguous_reference`, `invalid_input`, `claim_conflict`, `unavailable`,
  /// `configuration`, `unauthorized`, `network` or `internal`.
  final String type;
  final String message;
  final List<String> candidates;

  Json toJson() => {
    'error': {'type': type, 'message': message, if (candidates.isNotEmpty) 'candidates': candidates},
  };

  @override
  String toString() => message;
}
