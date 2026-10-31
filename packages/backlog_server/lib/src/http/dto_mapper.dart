import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';

/// Translates core domain objects into the API contract.
abstract final class DtoMapper {
  static WorkflowDto workflow(Workflow workflow) => WorkflowDto(
    statuses: [
      for (final status in workflow.statuses)
        StatusDto(id: status.id, category: _category(status.category)!, pickable: status.pickable),
    ],
    priorities: workflow.priorities,
    types: workflow.types,
    milestones: [
      for (final milestone in workflow.milestones)
        MilestoneDto(id: milestone.id, title: milestone.title, due: milestone.due),
    ],
    defaultStatus: workflow.defaultStatus,
    defaultPriority: workflow.defaultPriority,
    defaultType: workflow.defaultType,
    appearance: _appearance(workflow.appearance),
  );

  static AppearanceDto _appearance(Appearance appearance) {
    PaletteDto palette(Palette palette) => PaletteDto(
      seed: palette.seed,
      primary: palette.primary,
      secondary: palette.secondary,
      background: palette.background,
    );
    return AppearanceDto(
      mode: appearance.mode,
      light: palette(appearance.light),
      dark: palette(appearance.dark),
      statuses: appearance.statuses,
      priorities: appearance.priorities,
      types: appearance.types,
      labels: appearance.labels,
    );
  }

  static ItemDto item(PlannedItem planned, {String? path, bool withBody = false}) {
    final item = planned.item;
    final claim = planned.claim;
    return ItemDto(
      id: item.id.value,
      title: item.title,
      type: item.type,
      status: item.status,
      category: _category(planned.category),
      priority: item.priority,
      milestone: item.milestone,
      parent: item.parent?.value,
      dependsOn: [for (final id in item.dependsOn) id.value],
      related: [for (final id in item.related) id.value],
      assignee: item.assignee,
      branch: item.branch,
      pr: item.pr,
      labels: item.labels,
      docs: item.docs,
      touches: item.touches,
      created: item.created,
      updated: item.updated,
      extra: item.extra,
      ready: planned.isReady,
      blocked: planned.isBlocked,
      blockedBy: [
        for (final id in [...planned.openDependencies, ...planned.missingDependencies]) id.value,
      ],
      conflicting: planned.isConflicting,
      conflictsWith: [for (final id in planned.conflictsWith) id.value],
      children: Progress(planned.childCount - planned.openChildCount, planned.childCount),
      checklist: Progress(planned.checklist.done, planned.checklist.total),
      claim: claim == null ? null : DtoMapper.claim(claim, expired: planned.isClaimExpired),
      path: path,
      body: withBody ? item.body : null,
    );
  }

  static ItemDetailDto detail(PlannedItem planned, BacklogSnapshot snapshot, {String? path}) {
    final item = planned.item;
    return ItemDetailDto(
      item: DtoMapper.item(planned, path: path, withBody: true),
      parent: item.parent == null ? null : _link(item.parent!, snapshot),
      children: [for (final child in snapshot.childrenOf(item.id)) _link(child.id, snapshot)],
      dependencies: [for (final id in item.dependsOn) _link(id, snapshot)],
      dependents: [for (final other in snapshot.dependentsOf(item.id)) _link(other.id, snapshot)],
      related: [for (final id in item.related) _link(id, snapshot)],
      conflicts: [for (final id in planned.conflictsWith) _link(id, snapshot)],
      waiting: [for (final other in snapshot.waitingOn(item.id)) _link(other.id, snapshot)],
    );
  }

  static ClaimDto claim(Claim claim, {bool expired = false}) => ClaimDto(
    item: claim.itemId.value,
    agent: claim.agent,
    claimedAt: claim.claimedAt,
    heartbeatAt: claim.heartbeatAt,
    expiresAt: claim.expiresAt,
    expired: expired,
  );

  static ViewSummaryDto viewSummary(ViewDefinition view, {int? count}) => ViewSummaryDto(
    id: view.id,
    name: view.name,
    layout: ViewLayoutDto.parse(view.layout.name),
    groupBy: view.groupBy,
    section: view.section,
    pinned: view.pinned,
    count: count,
  );

  static ViewResultDto view(ViewResult result) {
    final definition = result.definition;
    return ViewResultDto(
      id: definition.id,
      name: definition.name,
      layout: ViewLayoutDto.parse(definition.layout.name),
      groupBy: definition.groupBy,
      fields: definition.fields,
      columns: definition.columns,
      hidden: result.hidden,
      groups: [
        for (final group in result.groups) ViewGroupDto(group.key, [for (final planned in group.items) item(planned)]),
      ],
    );
  }

  static LintIssueDto lintIssue(LintIssue issue) => LintIssueDto(
    severity: issue.severity.name,
    code: issue.code,
    message: issue.message,
    item: issue.item,
    location: issue.location,
  );

  /// HTTP status and error payload for a domain error.
  static BacklogApiException error(BacklogException error) => switch (error) {
    NotFoundException() => BacklogApiException(404, 'not_found', error.message),
    AmbiguousReferenceException(:final candidates) => BacklogApiException(
      409,
      'ambiguous_reference',
      error.message,
      candidates: candidates,
    ),
    InvalidInputException() => BacklogApiException(400, 'invalid_input', error.message),
    ClaimConflictException() => BacklogApiException(409, 'claim_conflict', error.message),
    ConfigurationException() => BacklogApiException(500, 'configuration', error.message),
    UnavailableException() => BacklogApiException(409, 'unavailable', error.message),
  };

  static DispatchDto dispatch(DispatchPlan plan) => DispatchDto(
    configured: true,
    mode: plan.mode.name,
    agent: plan.config.agent.name,
    maxAgents: plan.config.maxAgents,
    running: plan.running,
    capacity: plan.capacity,
    worktrees: [
      for (final worktree in plan.worktrees)
        DispatchWorktreeDto(
          name: worktree.name,
          path: worktree.path,
          busy: worktree.isBusy,
          claims: [for (final claim in worktree.claims) claim.itemId.value],
          unavailable: worktree.unavailable,
          run: switch (worktree.run) {
            final run? => AgentRunDto(
              item: run.item.value,
              worktree: run.worktree,
              pid: run.pid,
              startedAt: run.startedAt,
              log: run.log,
              agent: run.agent,
              branch: run.branch,
            ),
            null => null,
          },
        ),
    ],
    assignments: [
      for (final assignment in plan.assignments)
        DispatchAssignmentDto(
          item: assignment.id.value,
          title: assignment.item.item.title,
          worktree: assignment.agent,
          resume: assignment.resume?.id,
        ),
    ],
    waiting: [for (final item in plan.waiting) item.id.value],
    held: [
      for (final (:item, :reason) in plan.held)
        HeldItemDto(item: item.id.value, title: item.item.title, reason: reason),
    ],
    sessions: [
      for (final id in plan.sessions.keys)
        if (plan.resumableSession(id) case final session?)
          AgentSessionDto(
            item: id.value,
            session: session.id,
            worktree: session.worktree,
            endedAt: session.endedAt,
            reason: session.reason,
          ),
    ],
  );

  static ItemLinkDto _link(ItemId id, BacklogSnapshot snapshot) {
    final other = snapshot[id];
    return other == null
        ? ItemLinkDto(id: id.value)
        : ItemLinkDto(
            id: id.value,
            title: other.item.title,
            status: other.item.status,
            category: _category(other.category),
          );
  }

  static StatusCategoryDto? _category(StatusCategory? category) =>
      category == null ? null : StatusCategoryDto.values.byName(category.name);
}
