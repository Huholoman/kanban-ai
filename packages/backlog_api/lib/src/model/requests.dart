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
    this.touches = const [],
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
    touches: json.strings('touches'),
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
  final List<String> touches;
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
    'touches': touches,
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

/// Changes a saved view: its section in the view list and/or the groups it
/// shows. Only what was given is changed; null or empty values remove the
/// key from the YAML (no section, default groups).
final class ViewUpdateRequest {
  const ViewUpdateRequest({
    this.section,
    this.columns,
    this.pinned,
    this.changesSection = false,
    this.changesColumns = false,
  });

  const ViewUpdateRequest.section(this.section)
    : columns = null,
      pinned = null,
      changesSection = true,
      changesColumns = false;

  const ViewUpdateRequest.columns(this.columns)
    : section = null,
      pinned = null,
      changesSection = false,
      changesColumns = true;

  const ViewUpdateRequest.pinned(bool this.pinned)
    : section = null,
      columns = null,
      changesSection = false,
      changesColumns = false;

  factory ViewUpdateRequest.fromJson(Json json) => ViewUpdateRequest(
    section: json.optionalString('section'),
    columns: json['columns'] == null ? null : json.strings('columns'),
    pinned: json['pinned'] as bool?,
    changesSection: json.containsKey('section'),
    changesColumns: json.containsKey('columns'),
  );

  final String? section;
  final List<String>? columns;

  /// Pin to (true) or unpin from (false) the phone's bottom bar; null keeps it.
  final bool? pinned;
  final bool changesSection;
  final bool changesColumns;

  Json toJson() => {if (changesSection) 'section': section, if (changesColumns) 'columns': columns, 'pinned': ?pinned};
}

/// A new saved view: a copy of [base] (layout, grouping, columns, sorting)
/// whose filter also requires every one of [conditions] — filter expressions
/// in the view YAML grammar, e.g. `{"labels": ["ui"]}`.
final class NewViewRequest {
  const NewViewRequest({required this.name, this.section, this.pinned = false, this.base, this.conditions = const []});

  factory NewViewRequest.fromJson(Json json) => NewViewRequest(
    name: json.string('name'),
    section: json.optionalString('section'),
    pinned: json.boolean('pinned'),
    base: json.optionalString('base'),
    conditions: switch (json['conditions']) {
      null => const [],
      final List<Object?> list => list,
      _ => throw const MalformedPayloadException('"conditions" must be a list.'),
    },
  );

  final String name;
  final String? section;
  final bool pinned;
  final String? base;
  final List<Object?> conditions;

  Json toJson() => {'name': name, 'section': section, 'pinned': pinned, 'base': base, 'conditions': conditions};
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
