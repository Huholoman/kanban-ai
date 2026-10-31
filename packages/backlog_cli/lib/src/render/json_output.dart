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
      'extra': item.extra,
      'ready': planned.isReady,
      'blocked': planned.isBlocked,
      'blocked_by': [
        for (final id in [...planned.openDependencies, ...planned.missingDependencies]) id.value,
      ],
      'children': {'total': planned.childCount, 'open': planned.openChildCount},
      'progress': {'done': checklist.done, 'total': checklist.total},
      'claim': planned.claim == null ? null : claim(planned.claim!, expired: planned.isClaimExpired),
      'path': ?path,
      if (withBody) 'body': item.body,
    };
  }

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
      },
      'message': error.message,
      if (error is AmbiguousReferenceException) 'candidates': error.candidates,
    },
  };
}
