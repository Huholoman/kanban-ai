import 'json.dart';

/// One entry of `dispatcher.actions`: a button on items and/or a hook that
/// runs when an item enters a status.
final class ActionDto {
  const ActionDto({
    required this.name,
    required this.kind,
    this.statuses,
    this.onEnter,
    this.agent,
    this.fresh = false,
  });

  factory ActionDto.fromJson(Json json) => ActionDto(
    name: json.string('name'),
    kind: json.string('kind'),
    statuses: json['statuses'] == null ? null : json.strings('statuses'),
    onEnter: json.optionalString('on_enter'),
    agent: json.optionalString('agent'),
    fresh: json.boolean('fresh'),
  );

  final String name;

  /// `prompt` (an agent), `command` or `builtin`.
  final String kind;

  /// Statuses whose items show it as a button; null: every status (or only
  /// [onEnter] when set).
  final List<String>? statuses;

  /// It runs by itself when an item enters this status.
  final String? onEnter;

  /// The agent profile of a prompt action.
  final String? agent;

  /// A prompt action starts a new session instead of continuing the item's.
  final bool fresh;

  bool get isPrompt => kind == 'prompt';

  /// Whether items in [status] show it as a button.
  bool offeredIn(String status) => switch (statuses) {
    final listed? => listed.contains(status),
    null => onEnter == null || onEnter == status,
  };

  Json toJson() => {
    'name': name,
    'kind': kind,
    'statuses': statuses,
    'on_enter': onEnter,
    'agent': agent,
    'fresh': fresh,
  };
}

/// An `on_enter` action waiting to run (`GET /api/dispatch`).
final class PendingActionDto {
  const PendingActionDto({required this.item, required this.action, required this.status, required this.since});

  factory PendingActionDto.fromJson(Json json) => PendingActionDto(
    item: json.string('item'),
    action: json.string('action'),
    status: json.string('status'),
    since: DateTime.parse(json.string('since')),
  );

  final String item;
  final String action;

  /// The status the item entered.
  final String status;
  final DateTime since;

  Json toJson() => {'item': item, 'action': action, 'status': status, 'since': since.toUtc().toIso8601String()};
}
