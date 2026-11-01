import 'package:backlog_core/backlog_core.dart';

/// JSON shapes of the CLI. Agents parse these, so fields are only ever added,
/// never renamed.
abstract final class JsonOutput {
  static Map<String, Object?> item(PlannedItem planned, {String? path, bool withBody = false}) {
    final item = planned.item;
    final checklist = planned.checklist;
    return {
      'id': item.id.value,
      'title': item.title,
      'type': item.type,
      'status': item.status,
      'category': planned.category?.name,
      'priority': item.priority,
      'milestone': item.milestone,
      'parent': item.parent?.value,
      'depends_on': [for (final id in item.dependsOn) id.value],
      'related': [for (final id in item.related) id.value],
      'assignee': item.assignee,
      'branch': item.branch,
      'pr': item.pr,
      'labels': item.labels,
      'docs': item.docs,
      'touches': item.touches,
      'created': item.created,
      'updated': item.updated,
      'created_at': _instant(item.created),
      'updated_at': _instant(item.updated),
      'extra': item.extra,
      'ready': planned.isReady,
      'blocked': planned.isBlocked,
      'blocked_by': [
        for (final id in [...planned.openDependencies, ...planned.missingDependencies]) id.value,
      ],
      'conflicting': planned.isConflicting,
      'conflicts_with': [for (final id in planned.conflictsWith) id.value],
      'children': {'total': planned.childCount, 'open': planned.openChildCount},
      'progress': {'done': checklist.done, 'total': checklist.total},
      'claim': planned.claim == null ? null : claim(planned.claim!, expired: planned.isClaimExpired),
      'needs_human': planned.needsHuman,
      'review': planned.review.name,
      'review_findings': planned.reviewFindings,
      'path': ?path,
      if (withBody) 'body': item.body,
      if (withBody) 'discussion': [for (final c in item.discussion.comments) comment(c)],
      if (withBody) 'checklist': [for (final entry in Checklist.entriesOf(item.body)) checklistEntry(entry)],
    };
  }

  /// A `created`/`updated` value as an ISO instant in UTC; null for a day
  /// (older files) or none.
  static String? _instant(String? value) => ItemTime.hasTime(value) ? ItemTime.parse(value)!.toIso8601String() : null;

  static Map<String, Object?> historyEntry(HistoryEntry entry) => {
    'kind': entry.kind.name,
    'at': entry.at.toUtc().toIso8601String(),
    'author': entry.author,
    'field': entry.field,
    'before': entry.before,
    'after': entry.after,
    'text': entry.text,
    'tag': entry.tag,
    'commit': entry.commit,
    'uncommitted': entry.uncommitted,
    'log': entry.log,
  };

  static Map<String, Object?> checklistEntry(ChecklistEntry entry) => {
    'number': entry.number,
    'text': entry.text,
    'done': entry.done,
  };

  static Map<String, Object?> comment(Comment comment) => {
    'author': comment.author,
    'at': comment.at.toUtc().toIso8601String(),
    'text': comment.text,
    'question': comment.question,
    'note': comment.note,
    'review': comment.review?.name,
    'commit': comment.commit,
  };

  static Map<String, Object?> claim(Claim claim, {bool? expired}) => {
    'item': claim.itemId.value,
    'agent': claim.agent,
    'claimed_at': claim.claimedAt.toUtc().toIso8601String(),
    'heartbeat_at': claim.heartbeatAt.toUtc().toIso8601String(),
    'expires_at': claim.expiresAt.toUtc().toIso8601String(),
    'expired': ?expired,
  };

  static Map<String, Object?> view(ViewResult result) => {
    'id': result.definition.id,
    'name': result.definition.name,
    'layout': result.definition.layout.name,
    'group_by': result.definition.groupBy,
    'fields': result.definition.fields,
    'hidden': result.hidden,
    'groups': [
      for (final group in result.groups)
        {
          'key': group.key,
          'items': [for (final planned in group.items) item(planned)],
        },
    ],
  };

  static Map<String, Object?> epic(EpicPlan plan) => {
    'epic': plan.id.value,
    'title': plan.epic.item.title,
    'branch': plan.branch,
    'verdict': plan.verdict.name,
    'problems': plan.problems,
    'warnings': plan.warnings,
    'finished': plan.finished,
    'next': plan.next?.id.value,
    'members': [
      for (final member in plan.members)
        {
          'id': member.id.value,
          'title': member.item.item.title,
          'status': member.item.item.status,
          'state': member.state.id,
          'after': [for (final id in member.after) id.value],
          'waits': member.waits,
          'milestone': member.item.item.milestone,
          'in_scope': member.inScope,
        },
    ],
    'milestone': plan.milestone,
    'skipped': [for (final member in plan.skipped) member.id.value],
    'progress': [
      for (final progress in plan.progress)
        {'milestone': progress.milestone, 'settled': progress.settled, 'total': progress.total},
    ],
  };

  static Map<String, Object?> lintIssue(LintIssue issue) => {
    'severity': issue.severity.name,
    'code': issue.code,
    'message': issue.message,
    'item': issue.item,
    'location': issue.location,
  };

  static Map<String, Object?> error(BacklogException error) => {
    'error': {
      'type': switch (error) {
        NotFoundException() => 'not_found',
        AmbiguousReferenceException() => 'ambiguous_reference',
        InvalidInputException() => 'invalid_input',
        ClaimConflictException() => 'claim_conflict',
        ConfigurationException() => 'configuration',
        UnavailableException() => 'unavailable',
      },
      'message': error.message,
      if (error is AmbiguousReferenceException) 'candidates': error.candidates,
    },
  };
}
