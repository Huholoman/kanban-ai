import 'package:collection/collection.dart';

import '../../items/domain/checklist.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_time.dart';

/// What a [HistoryEntry] records.
enum HistoryKind {
  /// The item came into being.
  created,

  /// A front-matter field changed ([HistoryEntry.field], before → after);
  /// `checklist` is the progress of the checklist (`1/3` → `2/3`).
  field,

  /// The description (the body without its discussion) changed.
  body,

  /// A comment, question, note or review in the discussion.
  comment,

  /// An agent or action ran for the item.
  run,
}

/// One thing that happened to an item: who, when, what.
final class HistoryEntry {
  const HistoryEntry({
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

  final HistoryKind kind;
  final DateTime at;

  /// Who did it: the author of the comment, the agent (worktree) of a run,
  /// the git author of the commit for changes; null when unknown.
  final String? author;

  /// The changed field ([HistoryKind.field]).
  final String? field;
  final String? before;
  final String? after;

  /// The comment's text; for a run what ran and how it ended.
  final String? text;

  /// `question`, `note`, `review ok`, `review changes` for comments; the
  /// action's name for runs of actions.
  final String? tag;

  /// The commit of the backlog repository that recorded the change; null
  /// for comments, runs and [uncommitted] changes.
  final String? commit;

  /// The change is in the file but not committed yet.
  final bool uncommitted;

  /// The log file of a run.
  final String? log;

  /// Changes of the status (and the item's creation).
  bool get isStatus => kind == HistoryKind.created || (kind == HistoryKind.field && field == 'status');

  @override
  String toString() =>
      '${ItemTime.format(at)} ${kind.name}${field == null ? '' : ' $field'}'
      '${before == null && after == null ? '' : ': ${before ?? '-'} → ${after ?? '-'}'}'
      '${author == null ? '' : ' by $author'}';
}

/// A version of an item: as committed to the backlog's git repository
/// ([commit]), or the file as it is now when that differs (no commit).
final class ItemRevision {
  const ItemRevision({required this.item, required this.at, this.commit, this.author});

  final Item item;

  /// When it was committed (or, uncommitted, the item's `updated`).
  final DateTime at;
  final String? commit;
  final String? author;
}

/// A finished or running agent or action run of an item, from the
/// dispatcher's logs.
final class RunRecord {
  const RunRecord({
    required this.startedAt,
    required this.log,
    this.agent,
    this.action,
    this.worktree,
    this.started,
    this.ended,
  });

  final DateTime startedAt;
  final String log;

  /// The agent profile (`claude`), null for a command or built-in action.
  final String? agent;

  /// The action that ran (also one an agent runs, like a review), null for
  /// an agent working on the item.
  final String? action;
  final String? worktree;

  /// The log's line about the start, without its prefix.
  final String? started;

  /// The log's line about the end (`the agent exited with code 0; …`);
  /// null while it runs.
  final String? ended;
}

/// Port: the committed versions of an item, oldest first.
abstract interface class ItemRevisions {
  /// Versions of item [id], whose file is now at [path] (absolute), decoded
  /// with [decode]; versions that do not decode are left out. Empty when the
  /// backlog is no git repository or the file was never committed.
  Future<List<ItemRevision>> of(String path, ItemId id, Item Function(String text) decode);
}

/// Builds the history of an item from its revisions, its discussion and its
/// runs.
abstract final class ItemHistory {
  /// Fields whose changes are not worth an entry.
  static const _skipped = {'id', 'created', 'updated'};

  /// Entries oldest first. [revisions] are the committed versions, oldest
  /// first; [current] is the item as it is now (an extra, uncommitted
  /// revision when it differs from the last one).
  static List<HistoryEntry> build({
    required Item current,
    List<ItemRevision> revisions = const [],
    List<RunRecord> runs = const [],
    DateTime? now,
  }) {
    final versions = [...revisions];
    if (versions.isEmpty || !_same(versions.last.item, current)) {
      versions.add(ItemRevision(item: current, at: _uncommittedAt(current, versions.lastOrNull, now)));
    }
    final entries = <HistoryEntry>[];
    final first = versions.first;
    entries.add(
      HistoryEntry(
        kind: HistoryKind.created,
        at: first.item.createdAt ?? first.at,
        author: first.author,
        after: first.item.status,
        commit: first.commit,
        uncommitted: first.commit == null,
      ),
    );
    for (var index = 1; index < versions.length; index++) {
      final previous = versions[index - 1];
      final next = versions[index];
      // A commit may hold several changes; `updated` tells when the last one was made.
      final updated = next.item.updatedAt;
      final at =
          updated != null &&
              ItemTime.hasTime(next.item.updated) &&
              updated.isAfter(previous.at) &&
              !updated.isAfter(next.at)
          ? updated
          : next.at;
      HistoryEntry change(HistoryKind kind, {String? field, String? before, String? after}) => HistoryEntry(
        kind: kind,
        at: at,
        author: next.author,
        field: field,
        before: before,
        after: after,
        commit: next.commit,
        uncommitted: next.commit == null,
      );
      final before = _fields(previous.item);
      final after = _fields(next.item);
      for (final key in {...before.keys, ...after.keys}) {
        if (_skipped.contains(key) || before[key] == after[key]) continue;
        entries.add(change(HistoryKind.field, field: key, before: before[key], after: after[key]));
      }
      final checklistBefore = Checklist.parse(previous.item.body);
      final checklistAfter = Checklist.parse(next.item.body);
      if ('$checklistBefore' != '$checklistAfter') {
        entries.add(
          change(
            HistoryKind.field,
            field: 'checklist',
            before: checklistBefore.isEmpty ? null : '$checklistBefore',
            after: checklistAfter.isEmpty ? null : '$checklistAfter',
          ),
        );
      }
      if (_description(previous.item) != _description(next.item)) entries.add(change(HistoryKind.body));
    }
    for (final comment in current.discussion.comments) {
      entries.add(
        HistoryEntry(
          kind: HistoryKind.comment,
          at: comment.at.toUtc(),
          author: comment.author,
          text: comment.text,
          tag: comment.question
              ? 'question'
              : comment.note
              ? 'note'
              : comment.review == null
              ? null
              : 'review ${comment.review!.name}',
        ),
      );
    }
    for (final run in runs) {
      entries.add(
        HistoryEntry(
          kind: HistoryKind.run,
          at: run.startedAt.toUtc(),
          author: run.worktree,
          tag: run.action,
          text: run.ended ?? 'still running',
          log: run.log,
        ),
      );
    }
    return entries..sort((a, b) => a.at.compareTo(b.at));
  }

  /// [entries] with only those [only] names: `status`
  /// (status changes), `fields`, `comments`, `runs` (agents and actions).
  static List<HistoryEntry> filter(List<HistoryEntry> entries, String? only) => switch (only) {
    null || '' || 'all' => entries,
    'status' => [
      for (final entry in entries)
        if (entry.isStatus) entry,
    ],
    'fields' => [
      for (final entry in entries)
        if (entry.kind != HistoryKind.comment && entry.kind != HistoryKind.run) entry,
    ],
    'comments' => [
      for (final entry in entries)
        if (entry.kind == HistoryKind.comment) entry,
    ],
    'runs' || 'agents' => [
      for (final entry in entries)
        if (entry.kind == HistoryKind.run) entry,
    ],
    _ => throw ArgumentError.value(only, 'only', 'not one of status, fields, comments, runs'),
  };

  /// The filters [filter] knows.
  static const filters = ['status', 'fields', 'comments', 'runs'];

  /// When the uncommitted change was made: its `updated`, not before the
  /// last commit (a day from an older file is its midnight).
  static DateTime _uncommittedAt(Item current, ItemRevision? last, DateTime? now) {
    final updated = current.updatedAt;
    if (updated == null) return now ?? DateTime.now().toUtc();
    return last != null && updated.isBefore(last.at) ? last.at : updated;
  }

  /// The body without the discussion and with checkboxes cleared: ticking
  /// one is a checklist change, not an edit of the description.
  static String _description(Item item) =>
      Discussion.withoutDiscussion(item.body).replaceAll(RegExp(r'\[[xX]\]'), '[ ]').trim();

  static bool _same(Item a, Item b) =>
      const MapEquality<String, String?>().equals(_fields(a), _fields(b)) && a.body == b.body;

  /// Front-matter fields as text; lists joined with `, `.
  static Map<String, String?> _fields(Item item) {
    String? list(List<Object> values) => values.isEmpty ? null : values.join(', ');
    return {
      'title': item.title,
      'type': item.type,
      'status': item.status,
      'priority': item.priority,
      'rank': item.rank?.toString(),
      'milestone': item.milestone,
      'parent': item.parent?.value,
      'depends_on': list(item.dependsOn),
      'related': list(item.related),
      'assignee': item.assignee,
      'branch': item.branch,
      'pr': item.pr,
      'labels': list(item.labels),
      'docs': list(item.docs),
      'touches': list(item.touches),
      'created': item.created,
      'updated': item.updated,
      for (final MapEntry(:key, :value) in item.extra.entries)
        key: switch (value) {
          null => null,
          final List<Object?> values => values.isEmpty ? null : values.join(', '),
          _ => '$value',
        },
    };
  }
}
