import 'json.dart';

final class NewItemRequest {
  const NewItemRequest({
    required this.title,
    this.type,
    this.status,
    this.priority,
    this.milestone,
    this.parent,
    this.dependsOn = const [],
    this.labels = const [],
    this.body = '',
  });

  factory NewItemRequest.fromJson(Json json) => NewItemRequest(
    title: json.string('title'),
    type: json.optionalString('type'),
    status: json.optionalString('status'),
    priority: json.optionalString('priority'),
    milestone: json.optionalString('milestone'),
    parent: json.optionalString('parent'),
    dependsOn: json.strings('depends_on'),
    labels: json.strings('labels'),
    body: json.optionalString('body') ?? '',
  );

  final String title;
  final String? type;
  final String? status;
  final String? priority;
  final String? milestone;
  final String? parent;
  final List<String> dependsOn;
  final List<String> labels;
  final String body;

  Json toJson() => {
    'title': title,
    'type': ?type,
    'status': ?status,
    'priority': ?priority,
    'milestone': ?milestone,
    'parent': ?parent,
    'depends_on': dependsOn,
    'labels': labels,
    'body': body,
  };
}

/// Edits of one item in the CLI syntax (`status=done`, `labels+=ui`,
/// `milestone=` clears) plus an optional new Markdown body.
final class ItemUpdateRequest {
  const ItemUpdateRequest({this.changes = const [], this.body});

  factory ItemUpdateRequest.fromJson(Json json) =>
      ItemUpdateRequest(changes: json.strings('changes'), body: json.optionalString('body'));

  /// `field=value`; a list field takes comma-separated values.
  static String set(String field, Object? value) =>
      '$field=${value is Iterable<Object?> ? value.join(',') : value ?? ''}';

  static String add(String field, String value) => '$field+=$value';

  static String remove(String field, String value) => '$field-=$value';

  final List<String> changes;
  final String? body;

  bool get isEmpty => changes.isEmpty && body == null;

  Json toJson() => {'changes': changes, 'body': ?body};
}

/// Moves a view to another section of the view list; null or blank removes
/// it from its section.
final class ViewUpdateRequest {
  const ViewUpdateRequest({this.section});

  factory ViewUpdateRequest.fromJson(Json json) => ViewUpdateRequest(section: json.optionalString('section'));

  final String? section;

  Json toJson() => {'section': section};
}

/// Claim, release or completion of an item on behalf of [agent].
final class ClaimRequest {
  const ClaimRequest({this.agent, this.status, this.force = false});

  factory ClaimRequest.fromJson(Json json) => ClaimRequest(
    agent: json.optionalString('agent'),
    status: json.optionalString('status'),
    force: json.boolean('force'),
  );

  final String? agent;

  /// Target status for release and done; the workflow default otherwise.
  final String? status;
  final bool force;

  Json toJson() => {'agent': ?agent, 'status': ?status, 'force': force};
}
