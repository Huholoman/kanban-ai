import 'package:backlog_core/backlog_core.dart';

/// Human-oriented terminal output.
abstract final class TextOutput {
  /// Local time to the minute: `2026-10-29 15:31`.
  static String time(DateTime moment) {
    final local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${formatDay(local)} ${two(local.hour)}:${two(local.minute)}';
  }

  /// One aligned line per item.
  static List<String> rows(List<PlannedItem> items) {
    if (items.isEmpty) return const ['(nothing)'];
    final idWidth = items.map((i) => i.id.value.length).reduce((a, b) => a > b ? a : b);
    final statusWidth = items.map((i) => i.item.status.length).reduce((a, b) => a > b ? a : b);
    return [
      for (final planned in items)
        '${planned.id.value.padRight(idWidth)}  ${planned.item.priority}  '
            '${planned.item.status.padRight(statusWidth)}  ${planned.item.title}${_badges(planned)}',
    ];
  }

  static String _badges(PlannedItem planned) {
    final item = planned.item;
    final checklist = planned.checklist;
    final badges = [
      if (item.type != 'task') '<${item.type}>',
      if (item.milestone != null) '[${item.milestone}]',
      for (final label in item.labels) '#$label',
      if (planned.isClaimed) '@${planned.claim!.agent}',
      if (planned.isClaimExpired) '@${planned.claim!.agent} (claim expired)',
      if (planned.isBlocked) 'blocked by ${[...planned.openDependencies, ...planned.missingDependencies].join(',')}',
      if (planned.isConflicting) 'waits for ${planned.conflictsWith.join(',')} (touches overlap)',
      if (planned.needsHuman) 'needs a person (question by ${planned.item.discussion.openQuestion!.author})',
      ?_review(planned),
      if (planned.childCount > 0) 'children ${planned.childCount - planned.openChildCount}/${planned.childCount}',
      if (!checklist.isEmpty) 'checklist $checklist',
    ];
    return badges.isEmpty ? '' : '  ${badges.join(' ')}';
  }

  /// `review ok`, `review: 3 findings`, `review outdated`; null without one.
  static String? _review(PlannedItem planned) => switch (planned.review) {
    ReviewState.none || ReviewState.running => null,
    ReviewState.ok => 'review ok',
    ReviewState.changes =>
      'review: changes${planned.reviewFindings == 0 ? '' : ' (${planned.reviewFindings} findings)'}',
    ReviewState.stale => 'review outdated (newer commits)',
  };

  static List<String> detail(PlannedItem planned, BacklogSnapshot snapshot, {String? path}) {
    final item = planned.item;
    String describe(ItemId id) {
      final other = snapshot[id];
      return other == null ? '$id (missing)' : '$id ${other.item.title} (${other.item.status})';
    }

    final dependents = snapshot.dependentsOf(item.id);
    final children = snapshot.childrenOf(item.id);
    return [
      '${item.id}  ${item.title}',
      'type: ${item.type}   status: ${item.status}   priority: ${item.priority}'
          '${item.milestone == null ? '' : '   milestone: ${item.milestone}'}',
      if (item.parent != null) 'parent: ${describe(item.parent!)}',
      for (final id in item.dependsOn) 'depends on: ${describe(id)}',
      for (final other in dependents) 'blocks: ${describe(other.id)}',
      for (final child in children) 'child: ${describe(child.id)}',
      for (final id in item.related) 'related: ${describe(id)}',
      for (final id in planned.conflictsWith) 'waits for: ${describe(id)}, touches overlap',
      for (final other in snapshot.waitingOn(item.id)) 'holds up: ${describe(other.id)}, touches overlap',
      if (planned.isBlocked) 'BLOCKED',
      if (planned.isConflicting) 'WAITING',
      if (planned.needsHuman) 'NEEDS A PERSON: ${planned.item.discussion.openQuestion!.author} asked a question',
      if (planned.isReady) 'READY',
      if (_review(planned) case final review?)
        '${review.toUpperCase()} (${planned.item.discussion.lastReview!.author})',
      if (planned.claim != null)
        'claim: ${planned.claim!.agent} '
            '${planned.isClaimExpired ? 'expired' : 'until'} ${time(planned.claim!.expiresAt)}',
      if (item.assignee != null) 'assignee: ${item.assignee}',
      if (item.branch != null) 'branch: ${item.branch}',
      if (item.pr != null) 'pr: ${item.pr}',
      if (item.labels.isNotEmpty) 'labels: ${item.labels.join(', ')}',
      if (item.docs.isNotEmpty) 'docs: ${item.docs.join(', ')}',
      if (item.touches.isNotEmpty) 'touches: ${item.touches.join(', ')}',
      for (final MapEntry(:key, :value) in item.extra.entries) '$key: $value',
      if (!planned.checklist.isEmpty) 'checklist: ${planned.checklist}',
      'created: ${item.created ?? '-'}   updated: ${item.updated ?? '-'}',
      if (path != null) 'file: $path',
      if (item.body.trim().isNotEmpty) ...['', item.body.trimRight()],
    ];
  }

  static List<String> view(ViewResult result) {
    final definition = result.definition;
    final lines = ['${definition.name} (${definition.layout.name})'];
    if (definition.layout == ViewLayout.graph) {
      final items = result.items;
      final shown = {for (final planned in items) planned.id};
      for (final planned in items) {
        lines.add(rows([planned]).single);
        for (final dependency in planned.item.dependsOn) {
          lines.add('    └─ needs $dependency${shown.contains(dependency) ? '' : ' (not in view)'}');
        }
      }
      if (items.isEmpty) lines.add('(nothing)');
    } else if (definition.groupBy == null) {
      lines.addAll(rows(result.items));
    } else {
      for (final group in result.groups) {
        lines
          ..add('')
          ..add('== ${group.key.isEmpty ? '(none)' : group.key} (${group.items.length}) ==');
        if (group.items.isNotEmpty) lines.addAll(rows(group.items));
      }
    }
    if (result.hidden > 0) lines.add('\n${result.hidden} more item(s) outside the shown columns.');
    return lines;
  }

  static String lintIssue(LintIssue issue) => [
    issue.severity.name.padRight(7),
    '[${issue.code}]',
    if (issue.item != null) '${issue.item}:',
    issue.message,
    if (issue.location != null) '(${issue.location})',
  ].join(' ');
}
