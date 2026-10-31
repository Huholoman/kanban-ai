import 'action_dto.dart';
import 'discussion_dto.dart';
import 'json.dart';
import 'workflow_dto.dart';

final class ClaimDto {
  const ClaimDto({
    required this.item,
    required this.agent,
    required this.claimedAt,
    required this.heartbeatAt,
    required this.expiresAt,
    this.expired = false,
  });

  factory ClaimDto.fromJson(Json json) => ClaimDto(
    item: json.string('item'),
    agent: json.string('agent'),
    claimedAt: DateTime.parse(json.string('claimed_at')),
    heartbeatAt: DateTime.parse(json.string('heartbeat_at')),
    expiresAt: DateTime.parse(json.string('expires_at')),
    expired: json.boolean('expired'),
  );

  final String item;
  final String agent;
  final DateTime claimedAt;
  final DateTime heartbeatAt;
  final DateTime expiresAt;
  final bool expired;

  Json toJson() => {
    'item': item,
    'agent': agent,
    'claimed_at': claimedAt.toUtc().toIso8601String(),
    'heartbeat_at': heartbeatAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'expired': expired,
  };
}

/// `done` of `total`, for checklists and children.
final class Progress {
  const Progress(this.done, this.total);

  static const none = Progress(0, 0);

  final int done;
  final int total;

  bool get isEmpty => total == 0;

  @override
  String toString() => '$done/$total';
}

/// One item with its derived planning state. The same fields as
/// `backlog --json`, so agents and the UI see one shape.
final class ItemDto {
  const ItemDto({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    this.category,
    required this.priority,
    this.milestone,
    this.parent,
    this.dependsOn = const [],
    this.related = const [],
    this.assignee,
    this.branch,
    this.pr,
    this.labels = const [],
    this.docs = const [],
    this.touches = const [],
    this.created,
    this.updated,
    this.extra = const {},
    this.ready = false,
    this.blocked = false,
    this.blockedBy = const [],
    this.conflicting = false,
    this.conflictsWith = const [],
    this.children = Progress.none,
    this.checklist = Progress.none,
    this.claim,
    this.needsHuman = false,
    this.review = 'none',
    this.reviewFindings = 0,
    this.path,
    this.body,
  });

  factory ItemDto.fromJson(Json json) {
    final children = json.optionalObject('children') ?? const {};
    final progress = json.optionalObject('progress') ?? const {};
    final category = json.optionalString('category');
    final claim = json.optionalObject('claim');
    final total = children.integer('total');
    return ItemDto(
      id: json.string('id'),
      title: json.string('title'),
      type: json.string('type'),
      status: json.string('status'),
      category: category == null ? null : StatusCategoryDto.values.byName(category),
      priority: json.string('priority'),
      milestone: json.optionalString('milestone'),
      parent: json.optionalString('parent'),
      dependsOn: json.strings('depends_on'),
      related: json.strings('related'),
      assignee: json.optionalString('assignee'),
      branch: json.optionalString('branch'),
      pr: json.optionalString('pr'),
      labels: json.strings('labels'),
      docs: json.strings('docs'),
      touches: json.strings('touches'),
      created: json.optionalString('created'),
      updated: json.optionalString('updated'),
      extra: json.optionalObject('extra') ?? const {},
      ready: json.boolean('ready'),
      blocked: json.boolean('blocked'),
      blockedBy: json.strings('blocked_by'),
      conflicting: json.boolean('conflicting'),
      conflictsWith: json.strings('conflicts_with'),
      children: Progress(total - children.integer('open'), total),
      checklist: Progress(progress.integer('done'), progress.integer('total')),
      claim: claim == null ? null : ClaimDto.fromJson(claim),
      needsHuman: json.boolean('needs_human'),
      review: json.optionalString('review') ?? 'none',
      reviewFindings: json['review_findings'] == null ? 0 : json.integer('review_findings'),
      path: json.optionalString('path'),
      body: json.optionalString('body'),
    );
  }

  final String id;
  final String title;
  final String type;
  final String status;
  final StatusCategoryDto? category;
  final String priority;
  final String? milestone;
  final String? parent;
  final List<String> dependsOn;
  final List<String> related;
  final String? assignee;
  final String? branch;

  /// Link to the pull request, if one is open or merged.
  final String? pr;
  final List<String> labels;
  final List<String> docs;

  /// Paths and globs in the code repository the work will change.
  final List<String> touches;
  final String? created;
  final String? updated;
  final Json extra;
  final bool ready;
  final bool blocked;
  final List<String> blockedBy;

  /// Open, and its [touches] overlap work in progress: it waits for
  /// [conflictsWith].
  final bool conflicting;
  final List<String> conflictsWith;
  final Progress children;
  final Progress checklist;
  final ClaimDto? claim;

  /// An agent asked a question in the discussion that nobody answered yet;
  /// the item waits for a person (and is not ready).
  final bool needsHuman;

  /// Where the review of the item's work stands: `none`, `running` (an AI
  /// review runs or waits to run), `ok`, `changes` or `stale` (the branch
  /// has commits the latest review did not see).
  final String review;

  /// Findings of the latest review when it asks for changes, else 0.
  final int reviewFindings;

  /// Location of the file, relative to the backlog root.
  final String? path;

  /// Markdown body; only present in item details.
  final String? body;

  bool get isDone => category == StatusCategoryDto.done;

  /// Somebody holds a live claim on the item.
  bool get isClaimed => claim != null && !claim!.expired;

  Json toJson() => {
    'id': id,
    'title': title,
    'type': type,
    'status': status,
    'category': category?.name,
    'priority': priority,
    'milestone': milestone,
    'parent': parent,
    'depends_on': dependsOn,
    'related': related,
    'assignee': assignee,
    'branch': branch,
    'pr': pr,
    'labels': labels,
    'docs': docs,
    'touches': touches,
    'created': created,
    'updated': updated,
    'extra': extra,
    'ready': ready,
    'blocked': blocked,
    'blocked_by': blockedBy,
    'conflicting': conflicting,
    'conflicts_with': conflictsWith,
    'children': {'total': children.total, 'open': children.total - children.done},
    'progress': {'done': checklist.done, 'total': checklist.total},
    'claim': claim?.toJson(),
    'needs_human': needsHuman,
    'review': review,
    'review_findings': reviewFindings,
    'path': ?path,
    'body': ?body,
  };
}

/// A short reference to another item, as shown next to a detail.
final class ItemLinkDto {
  const ItemLinkDto({required this.id, this.title, this.status, this.category});

  factory ItemLinkDto.fromJson(Json json) {
    final category = json.optionalString('category');
    return ItemLinkDto(
      id: json.string('id'),
      title: json.optionalString('title'),
      status: json.optionalString('status'),
      category: category == null ? null : StatusCategoryDto.values.byName(category),
    );
  }

  final String id;

  /// Null when the referenced item does not exist.
  final String? title;
  final String? status;
  final StatusCategoryDto? category;

  bool get isMissing => title == null;

  Json toJson() => {'id': id, 'title': title, 'status': status, 'category': category?.name};
}

/// An item with its body and its neighbourhood in the backlog.
final class ItemDetailDto {
  const ItemDetailDto({
    required this.item,
    this.parent,
    this.children = const [],
    this.dependencies = const [],
    this.dependents = const [],
    this.related = const [],
    this.conflicts = const [],
    this.waiting = const [],
    this.discussion = const [],
    this.actions = const [],
  });

  factory ItemDetailDto.fromJson(Json json) {
    List<ItemLinkDto> links(String key) => json.objects(key).map(ItemLinkDto.fromJson).toList();
    final parent = json.optionalObject('parent');
    return ItemDetailDto(
      item: ItemDto.fromJson(json.object('item')),
      parent: parent == null ? null : ItemLinkDto.fromJson(parent),
      children: links('children'),
      dependencies: links('dependencies'),
      dependents: links('dependents'),
      related: links('related'),
      conflicts: links('conflicts'),
      waiting: links('waiting'),
      discussion: json.objects('discussion').map(CommentDto.fromJson).toList(),
      actions: json.objects('actions').map(ActionDto.fromJson).toList(),
    );
  }

  final ItemDto item;
  final ItemLinkDto? parent;
  final List<ItemLinkDto> children;
  final List<ItemLinkDto> dependencies;

  /// Items that depend on this one.
  final List<ItemLinkDto> dependents;
  final List<ItemLinkDto> related;

  /// Active items this one waits for because their `touches` overlap.
  final List<ItemLinkDto> conflicts;

  /// Open items waiting for this (active) one because of overlapping `touches`.
  final List<ItemLinkDto> waiting;

  /// The comments of the `## Discussion` section of the body, oldest first.
  final List<CommentDto> discussion;

  /// The actions the item's status offers as buttons (`dispatcher.actions`).
  final List<ActionDto> actions;

  Json toJson() => {
    'item': item.toJson(),
    'parent': parent?.toJson(),
    'children': [for (final link in children) link.toJson()],
    'dependencies': [for (final link in dependencies) link.toJson()],
    'dependents': [for (final link in dependents) link.toJson()],
    'related': [for (final link in related) link.toJson()],
    'conflicts': [for (final link in conflicts) link.toJson()],
    'waiting': [for (final link in waiting) link.toJson()],
    'discussion': [for (final comment in discussion) comment.toJson()],
    'actions': [for (final action in actions) action.toJson()],
  };
}
