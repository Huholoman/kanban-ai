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
    this.review = false,
    this.autoFix = 0,
    this.changesCode = false,
  });

  factory ActionDto.fromJson(Json json) => ActionDto(
    name: json.string('name'),
    kind: json.string('kind'),
    statuses: json['statuses'] == null ? null : json.strings('statuses'),
    onEnter: json.optionalString('on_enter'),
    agent: json.optionalString('agent'),
    fresh: json.boolean('fresh'),
    review: json.boolean('review'),
    autoFix: json['auto_fix'] == null ? 0 : json.integer('auto_fix'),
    changesCode: json.boolean('changes_code'),
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

  /// An AI review (`review: true`): a prompt action with the built-in review
  /// task that ends with `backlog review`.
  final bool review;

  /// For a [review]: at most this many automatic fix rounds by the item's
  /// agent when it asks for changes (0: none).
  final int autoFix;

  /// A prompt action whose agent changes code: the item shows in progress
  /// while it runs.
  final bool changesCode;

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
    'review': review,
    'auto_fix': autoFix,
    'changes_code': changesCode,
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
