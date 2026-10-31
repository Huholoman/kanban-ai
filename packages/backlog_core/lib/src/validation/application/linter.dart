import 'package:path/path.dart' as p;

import '../../claims/domain/claim.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../items/domain/item_repository.dart';
import '../../items/domain/path_glob.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
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
    String? root,
    Future<bool> Function(String path)? directoryExists,
    Future<bool> Function(String program)? programExists,
  }) : _items = items,
       _claims = claims,
       _views = views,
       _workflow = workflow,
       _clock = clock,
       _root = root,
       _directoryExists = directoryExists,
       _programExists = programExists;

  final ItemRepository _items;
  final ClaimStore _claims;
  final ViewRepository _views;
  final Workflow _workflow;
  final Clock _clock;

  /// The backlog folder and a way to look at the disk; without them the
  /// dispatcher's worktree folders are not checked.
  final String? _root;
  final Future<bool> Function(String path)? _directoryExists;

  /// Whether a program can be started (found on the PATH); without it the
  /// dispatcher's agent command is not checked.
  final Future<bool> Function(String program)? _programExists;

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

    final active = snapshot.items.where((p) => p.category == StatusCategory.active && p.item.touches.isNotEmpty);
    final seenActive = <PlannedItem>[];
    for (final planned in active) {
      final globs = [for (final pattern in planned.item.touches) PathGlob(pattern)];
      for (final other in seenActive) {
        if (PathGlob.anyOverlap(globs, [for (final pattern in other.item.touches) PathGlob(pattern)])) {
          issues.add(
            LintIssue(
              Severity.warning,
              'touches-overlap',
              'In progress together with ${other.id}, and their touches overlap.',
              item: '${planned.id}',
            ),
          );
        }
      }
      seenActive.add(planned);
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

    final dispatcher = _workflow.dispatcher;
    final root = _root, exists = _directoryExists;
    if (dispatcher != null && root != null && exists != null) {
      for (final worktree in dispatcher.worktrees) {
        final path = worktree.resolvePath(root);
        if (!await exists(path)) {
          issues.add(
            LintIssue(
              Severity.warning,
              'dispatcher-worktree',
              'Dispatcher worktree "${worktree.name}" points to $path, which is not a folder.',
              location: 'backlog.yaml',
            ),
          );
        }
      }
      if (dispatcher.newWorktrees case final added?) {
        final repo = added.resolveRepo(root);
        if (!await exists(repo)) {
          issues.add(
            LintIssue(
              Severity.warning,
              'dispatcher-repo',
              'dispatcher.repo points to $repo, which is not a folder; no worktrees can be added.',
              location: 'backlog.yaml',
            ),
          );
        }
      }
    }
    final programExists = _programExists;
    if (dispatcher != null && programExists != null) {
      final agent = dispatcher.agent;
      if (!await programExists(agent.command.executable)) {
        issues.add(
          LintIssue(
            Severity.warning,
            'dispatcher-agent',
            'Dispatcher agent "${agent.name}" runs "${agent.command.executable}", which is not on the PATH.',
            location: 'backlog.yaml',
          ),
        );
      }
      if (!agent.verified) {
        issues.add(
          LintIssue(
            Severity.warning,
            'dispatcher-agent',
            'Dispatcher agent "${agent.name}" is an unverified preset; check its command or define your own in '
                'dispatcher.agents.',
            location: 'backlog.yaml',
          ),
        );
      }
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

    for (final pattern in item.touches) {
      if (PathGlob.problem(pattern) case final problem?) {
        report(Severity.warning, 'invalid-touches', '"touches" entry "$pattern" $problem.');
      }
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
