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

  /// What the change concerns, so that clients reload only that: `backlog.yaml`
  /// the workflow, `items/` and `.locks/` (claims) the items, `views/` the
  /// views, a dispatch event the plan; `docs/` nothing, any other path
  /// everything.
  Set<BacklogPart> get parts {
    if (isDispatch) return const {BacklogPart.plan};
    final parts = <BacklogPart>{};
    for (final path in paths) {
      final top = path.split('/').first;
      switch (top) {
        case 'backlog.yaml':
          parts.add(BacklogPart.workflow);
        case 'items' || '.locks':
          parts.add(BacklogPart.items);
        case 'views':
          parts.add(BacklogPart.views);
        case 'docs':
          break;
        default:
          return BacklogPart.values.toSet();
      }
    }
    return parts;
  }

  Json toJson() => {'type': type, 'paths': paths};
}

/// A part of a backlog a client shows, by [BacklogChangeEvent.parts].
enum BacklogPart {
  /// `backlog.yaml`: workflow, appearance, dispatcher settings.
  workflow,

  /// Item files and claims.
  items,

  /// Saved views.
  views,

  /// The dispatcher's plan.
  plan,
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
