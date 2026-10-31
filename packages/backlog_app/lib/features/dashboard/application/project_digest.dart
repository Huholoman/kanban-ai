import 'package:backlog_api/backlog_api.dart';

/// `done` of `total` items of one milestone.
typedef MilestoneProgress = ({MilestoneDto milestone, int done, int total});

/// What the dashboard shows of one backlog, derived from its items, the
/// dispatcher's plan and lint: what waits for a person and what goes on.
/// Pure: no I/O, so the rules can be tested without a server.
final class ProjectDigest {
  const ProjectDigest({
    this.project,
    this.workflow,
    this.items = const [],
    this.plan = DispatchDto.off,
    this.lint = const [],
    this.questions = const {},
  });

  /// Null for a server with a single backlog.
  final ProjectDto? project;
  final WorkflowDto? workflow;

  /// Every item, finished ones too.
  final List<ItemDto> items;
  final DispatchDto plan;
  final List<LintIssueDto> lint;

  /// The open question of each item that [ItemDto.needsHuman].
  final Map<String, CommentDto> questions;

  /// The status whose items wait for approval (`review` in the presets).
  static const reviewStatus = 'review';

  /// The milestone of postponed work, never the current one.
  static const parkingLot = 'later';

  Iterable<ItemDto> get _open => items.where((item) => !item.isDone);

  /// Items whose agent asked a question nobody answered yet.
  List<ItemDto> get waitingForAnswer => [
    for (final item in _open)
      if (item.needsHuman) item,
  ];

  /// Items in [reviewStatus]: their work waits to be approved and merged.
  List<ItemDto> get toApprove => [
    for (final item in items)
      if (item.status == reviewStatus) item,
  ];

  /// Ready items the dispatcher does not start by itself, with the reason
  /// (an agent stopped or ended without finishing, a stuck branch, …).
  List<HeldItemDto> get held => plan.held;

  /// Unfinished items whose claim expired: their agent is gone.
  List<ItemDto> get expiredClaims => [
    for (final item in _open)
      if (item.claim?.expired ?? false) item,
  ];

  int get lintErrors => lint.where((issue) => issue.isError).length;

  int get lintWarnings => lint.length - lintErrors;

  /// Worktrees where no agent can start (uncommitted changes, …).
  List<DispatchWorktreeDto> get unavailableWorktrees => [
    for (final worktree in plan.worktrees)
      if (worktree.unavailable != null) worktree,
  ];

  /// Open items waiting because their touches overlap work in progress.
  List<ItemDto> get conflicting => [
    for (final item in _open)
      if (item.conflicting) item,
  ];

  /// How many things wait for a person: questions, approvals and held items.
  int get needsMe => waitingForAnswer.length + toApprove.length + held.length;

  /// Everything running: agents, commands and built-ins of actions.
  List<AgentRunDto> get runs {
    final runs = [...plan.runs];
    for (final worktree in plan.worktrees) {
      final run = worktree.run;
      if (run != null && !runs.any((r) => r.item == run.item)) runs.add(run);
    }
    return runs;
  }

  /// The item [id], if known.
  ItemDto? item(String id) => items.where((item) => item.id == id).firstOrNull;

  /// Progress of each milestone of the workflow that has items (epics left
  /// out: their children count).
  List<MilestoneProgress> get milestones => [
    for (final milestone in workflow?.milestones ?? const <MilestoneDto>[])
      if (_counted(milestone.id) case (final done, final total) when total > 0)
        (milestone: milestone, done: done, total: total),
  ];

  (int, int) _counted(String milestone) {
    var done = 0;
    var total = 0;
    for (final item in items) {
      if (item.milestone != milestone || item.type == 'epic') continue;
      total++;
      if (item.isDone) done++;
    }
    return (done, total);
  }

  /// The first milestone of the workflow with unfinished work, [parkingLot]
  /// aside.
  MilestoneDto? get currentMilestone {
    for (final milestone in workflow?.milestones ?? const <MilestoneDto>[]) {
      if (milestone.id == parkingLot) continue;
      if (_open.any((item) => item.milestone == milestone.id)) return milestone;
    }
    return null;
  }

  /// Unfinished items of the two most urgent priorities in the
  /// [currentMilestone] (in every milestone without one), in the default
  /// order (most urgent first).
  List<ItemDto> get urgent {
    final priorities = (workflow?.priorities ?? const ['p0', 'p1']).take(2).toSet();
    final current = currentMilestone?.id;
    return [
      for (final item in _open)
        if (priorities.contains(item.priority) && item.type != 'epic' && (current == null || item.milestone == current))
          item,
    ];
  }
}
