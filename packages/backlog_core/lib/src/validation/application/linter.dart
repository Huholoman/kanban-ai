import 'package:path/path.dart' as p;

import '../../claims/domain/claim.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_repository.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../shared/clock.dart';
import '../../views/domain/view.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/lint_issue.dart';

/// Checks that the backlog is consistent: every file parses, ids are unique,
/// values belong to the workflow, references point somewhere, there are no
/// cycles, and the claim locks match the items.
///
/// Agents edit item files by hand, so this is the safety net to run after
/// they do (and in CI, once the backlog is a git repository).
final class Linter {
  Linter({
    required ItemRepository items,
    required ClaimStore claims,
    required ViewRepository views,
    required Workflow workflow,
    required Clock clock,
  }) : _items = items,
       _claims = claims,
       _views = views,
       _workflow = workflow,
       _clock = clock;

  final ItemRepository _items;
  final ClaimStore _claims;
  final ViewRepository _views;
  final Workflow _workflow;
  final Clock _clock;

  Future<List<LintIssue>> run() async {
    final issues = <LintIssue>[];
    final catalog = await _items.load();
    final claims = await _claims.all();
    final now = _clock.now();

    for (final problem in catalog.problems) {
      issues.add(LintIssue(Severity.error, 'unreadable', problem.message, location: problem.location));
    }

    final seen = <ItemId, Item>{};
    for (final item in catalog.items) {
      if (seen.containsKey(item.id)) {
        issues.add(LintIssue(Severity.error, 'duplicate-id', 'Two items share this id.', item: '${item.id}'));
      }
      seen.putIfAbsent(item.id, () => item);
    }

    for (final item in seen.values) {
      await _checkItem(item, seen, issues);
    }

    final snapshot = BacklogSnapshot.build(items: seen.values, workflow: _workflow, claims: claims, now: now);
    for (final cycle in snapshot.dependencyCycles()) {
      issues.add(
        LintIssue(
          Severity.error,
          'dependency-cycle',
          'Dependency cycle: ${[...cycle, cycle.first].join(' → ')}.',
          item: '${cycle.first}',
        ),
      );
    }
    for (final cycle in snapshot.parentCycles()) {
      issues.add(
        LintIssue(
          Severity.error,
          'parent-cycle',
          'Parent cycle: ${[...cycle, cycle.first].join(' → ')}.',
          item: '${cycle.first}',
        ),
      );
    }

    for (final claim in claims) {
      final planned = snapshot[claim.itemId];
      if (planned == null) {
        issues.add(
          LintIssue(Severity.warning, 'orphan-claim', 'Lock for an item that does not exist.', item: '${claim.itemId}'),
        );
      } else if (planned.isDone) {
        issues.add(
          LintIssue(
            Severity.warning,
            'stale-claim',
            'Item is ${planned.item.status} but still claimed by ${claim.agent}.',
            item: '${claim.itemId}',
          ),
        );
      } else if (claim.isExpiredAt(now)) {
        issues.add(
          LintIssue(
            Severity.warning,
            'expired-claim',
            'Claim by ${claim.agent} expired at ${claim.expiresAt.toIso8601String()}.',
            item: '${claim.itemId}',
          ),
        );
      }
    }

    final views = await _views.load();
    for (final (location, message) in views.problems) {
      issues.add(LintIssue(Severity.error, 'invalid-view', message, location: location));
    }

    return issues..sort((a, b) => a.severity.index.compareTo(b.severity.index));
  }

  Future<void> _checkItem(Item item, Map<ItemId, Item> all, List<LintIssue> issues) async {
    void report(Severity severity, String code, String message) =>
        issues.add(LintIssue(severity, code, message, item: '${item.id}'));

    if (_workflow.status(item.status) == null) {
      report(Severity.error, 'unknown-status', 'Unknown status "${item.status}".');
    }
    if (!_workflow.hasPriority(item.priority)) {
      report(Severity.error, 'unknown-priority', 'Unknown priority "${item.priority}".');
    }
    if (!_workflow.hasType(item.type)) {
      report(Severity.error, 'unknown-type', 'Unknown type "${item.type}".');
    }
    if (item.milestone != null && !_workflow.acceptsMilestone(item.milestone!)) {
      report(Severity.warning, 'unknown-milestone', 'Milestone "${item.milestone}" is not listed in backlog.yaml.');
    }

    final references = {
      'parent': [?item.parent],
      'depends_on': item.dependsOn,
      'related': item.related,
    };
    references.forEach((field, ids) {
      for (final id in ids) {
        if (id == item.id) {
          report(Severity.error, 'self-reference', '"$field" points to the item itself.');
        } else if (!all.containsKey(id)) {
          report(Severity.error, 'dangling-reference', '"$field" points to $id, which does not exist.');
        }
      }
    });

    final location = await _items.locationOf(item.id);
    if (location != null) {
      final name = p.basename(location) == 'index.md' ? p.basename(p.dirname(location)) : p.basename(location);
      if (!name.toLowerCase().startsWith(item.id.value.toLowerCase())) {
        report(Severity.warning, 'file-name', 'File name "$name" does not start with the id.');
      }
    }
  }
}
