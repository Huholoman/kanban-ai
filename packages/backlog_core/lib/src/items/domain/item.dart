import 'package:collection/collection.dart';

import '../../shared/errors.dart';
import 'checklist.dart';
import 'discussion.dart';
import 'item_id.dart';
import 'item_time.dart';

/// A unit of planned work: an epic, story, task, bug, decision or idea.
///
/// Items are immutable; changes produce a new instance via [copyWith].
/// The item does not validate values against the workflow, so that a file an
/// agent wrote by hand can still be loaded and the linter can point at it.
final class Item {
  Item({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    required this.priority,
    this.milestone,
    this.parent,
    List<ItemId> dependsOn = const [],
    List<ItemId> related = const [],
    this.assignee,
    this.branch,
    this.pr,
    List<String> labels = const [],
    List<String> docs = const [],
    List<String> touches = const [],
    this.created,
    this.updated,
    Map<String, Object?> extra = const {},
    this.body = '',
  }) : dependsOn = List.unmodifiable(dependsOn),
       related = List.unmodifiable(related),
       labels = List.unmodifiable(labels),
       docs = List.unmodifiable(docs),
       touches = List.unmodifiable(touches),
       extra = Map.unmodifiable(extra) {
    if (title.trim().isEmpty) {
      throw InvalidInputException('Item $id has an empty title.');
    }
  }

  /// Front-matter keys with a meaning; everything else lands in [extra].
  static const fieldNames = [
    'id',
    'title',
    'type',
    'status',
    'priority',
    'milestone',
    'parent',
    'depends_on',
    'related',
    'assignee',
    'branch',
    'pr',
    'labels',
    'docs',
    'touches',
    'created',
    'updated',
  ];

  final ItemId id;
  final String title;
  final String type;
  final String status;
  final String priority;
  final String? milestone;

  /// The epic or story this item belongs to.
  final ItemId? parent;

  /// Items that must be done before this one can start.
  final List<ItemId> dependsOn;

  /// Loosely connected items; never block anything.
  final List<ItemId> related;
  final String? assignee;
  final String? branch;

  /// Link to the pull/merge request that delivers the item.
  final String? pr;
  final List<String> labels;

  /// Names of documents in the backlog's `docs/` folder.
  final List<String> docs;

  /// Paths and globs in the code repository the work is expected to change
  /// (see `PathGlob`); open items overlapping active ones wait for them.
  final List<String> touches;

  /// When the item was created and last changed, as written in the file
  /// (see [ItemTime]: a UTC instant, or a day in older files).
  final String? created;
  final String? updated;

  DateTime? get createdAt => ItemTime.parse(created);
  DateTime? get updatedAt => ItemTime.parse(updated);

  /// Unknown front-matter keys, kept so that rewriting a file never loses them.
  final Map<String, Object?> extra;

  /// Markdown after the front matter.
  final String body;

  Checklist get checklist => Checklist.parse(body);

  /// The `## Discussion` section of the [body].
  late final Discussion discussion = Discussion.parse(body);

  /// Nullable fields take a function so that they can be cleared:
  /// `copyWith(assignee: () => null)`.
  Item copyWith({
    String? title,
    String? type,
    String? status,
    String? priority,
    String? Function()? milestone,
    ItemId? Function()? parent,
    List<ItemId>? dependsOn,
    List<ItemId>? related,
    String? Function()? assignee,
    String? Function()? branch,
    String? Function()? pr,
    List<String>? labels,
    List<String>? docs,
    List<String>? touches,
    String? Function()? created,
    String? Function()? updated,
    Map<String, Object?>? extra,
    String? body,
  }) => Item(
    id: id,
    title: title ?? this.title,
    type: type ?? this.type,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    milestone: milestone == null ? this.milestone : milestone(),
    parent: parent == null ? this.parent : parent(),
    dependsOn: dependsOn ?? this.dependsOn,
    related: related ?? this.related,
    assignee: assignee == null ? this.assignee : assignee(),
    branch: branch == null ? this.branch : branch(),
    pr: pr == null ? this.pr : pr(),
    labels: labels ?? this.labels,
    docs: docs ?? this.docs,
    touches: touches ?? this.touches,
    created: created == null ? this.created : created(),
    updated: updated == null ? this.updated : updated(),
    extra: extra ?? this.extra,
    body: body ?? this.body,
  );

  /// This item with `updated` set to [now] when it differs from [before] in
  /// anything else; unchanged otherwise, so that a change that changes
  /// nothing leaves the file alone.
  Item touchedSince(Item before, DateTime now) =>
      _sameAs(before) ? copyWith(updated: () => before.updated) : copyWith(updated: () => ItemTime.format(now));

  static const _equality = DeepCollectionEquality();

  bool _sameAs(Item other) =>
      id == other.id &&
      title == other.title &&
      type == other.type &&
      status == other.status &&
      priority == other.priority &&
      milestone == other.milestone &&
      parent == other.parent &&
      _equality.equals(dependsOn, other.dependsOn) &&
      _equality.equals(related, other.related) &&
      assignee == other.assignee &&
      branch == other.branch &&
      pr == other.pr &&
      _equality.equals(labels, other.labels) &&
      _equality.equals(docs, other.docs) &&
      _equality.equals(touches, other.touches) &&
      created == other.created &&
      _equality.equals(extra, other.extra) &&
      body == other.body;

  @override
  String toString() => '$id $title';
}
