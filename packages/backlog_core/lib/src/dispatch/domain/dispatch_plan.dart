import 'package:collection/collection.dart';

import '../../claims/domain/claim.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
import '../../workflow/domain/dispatcher_config.dart';

/// A configured worktree at the moment of planning.
final class WorktreeState {
  const WorktreeState(this.worktree, this.path, this.claims);

  final WorktreeDefinition worktree;

  /// Absolute path of the worktree.
  final String path;

  /// Live claims held under the worktree's name (usually zero or one).
  final List<Claim> claims;

  String get name => worktree.name;

  /// An agent works here: some live claim is held under its name.
  bool get isBusy => claims.isNotEmpty;
}

/// "Start [item] in [worktree]": the agent takes the claim under the
/// worktree's name and runs [command] inside [path] with [environment].
final class DispatchAssignment {
  const DispatchAssignment({
    required this.item,
    required this.worktree,
    required this.path,
    required this.agentProfile,
    required this.prompt,
    required this.command,
    this.environment = const {},
  });

  /// Fills the [config]'s prompt, command and environment for [item] in
  /// [worktree] (absolute [path]); [backlogRoot] is the backlog folder.
  factory DispatchAssignment.render(
    DispatcherConfig config, {
    required PlannedItem item,
    required WorktreeDefinition worktree,
    required String path,
    required String backlogRoot,
  }) {
    final values = {
      'id': item.id.value,
      'title': item.item.title,
      'worktree': worktree.name,
      'path': path,
      'backlog': backlogRoot,
    };
    final prompt = config.prompt.render(values);
    final full = {...values, 'prompt': prompt};
    final profile = config.agent;
    return DispatchAssignment(
      item: item,
      worktree: worktree,
      path: path,
      agentProfile: profile,
      prompt: prompt,
      command: profile.command.render(full),
      environment: {
        'BACKLOG_AGENT': worktree.name,
        'BACKLOG_DIR': backlogRoot,
        for (final MapEntry(:key, :value) in profile.environment.entries) key: value.render(full),
      },
    );
  }

  final PlannedItem item;
  final WorktreeDefinition worktree;

  /// Absolute path of the worktree; the working directory of [command].
  final String path;

  /// The agent profile [command] comes from.
  final AgentProfile agentProfile;

  /// The rendered `dispatcher.prompt`.
  final String prompt;

  /// The profile's command with its placeholders filled in.
  final List<String> command;

  /// Set for the agent on top of the server's environment: `BACKLOG_AGENT`
  /// (the worktree name), `BACKLOG_DIR` (the backlog folder) and the
  /// profile's `env`.
  final Map<String, String> environment;

  ItemId get id => item.id;

  /// The name the claim is taken under.
  String get agent => worktree.name;

  /// `<id>@<worktree>`; equal keys mean the same decision.
  String get key => '$id@${worktree.name}';
}

/// What the dispatcher would do with one [BacklogSnapshot]: which ready items
/// go to which free worktrees, within the limit of concurrent agents.
///
/// Pure and deterministic: ready items in the order of `backlog next`
/// (priority, age, id), free worktrees in the configured order.
final class DispatchPlan {
  const DispatchPlan({
    required this.config,
    required this.takenAt,
    required this.worktrees,
    required this.assignments,
    required this.waiting,
    this.recheckAt,
  });

  /// The plan for [snapshot], or null when its workflow has no dispatcher.
  /// Relative worktree paths are resolved against [backlogRoot].
  static DispatchPlan? of(BacklogSnapshot snapshot, {required String backlogRoot}) {
    final config = snapshot.workflow.dispatcher;
    if (config == null) return null;

    final liveClaims = [
      for (final planned in snapshot.items)
        if (planned.isClaimed) planned.claim!,
    ];
    final worktrees = [
      for (final worktree in config.worktrees)
        WorktreeState(worktree, worktree.resolvePath(backlogRoot), [
          for (final claim in liveClaims)
            if (claim.agent == worktree.name) claim,
        ]),
    ];
    final running = worktrees.where((w) => w.isBusy).length;
    final free = worktrees.where((w) => !w.isBusy).toList();
    final slots = (config.maxAgents - running).clamp(0, free.length);
    final ready = snapshot.ready;

    final assignments = <DispatchAssignment>[
      for (var i = 0; i < slots && i < ready.length; i++)
        DispatchAssignment.render(
          config,
          item: ready[i],
          worktree: free[i].worktree,
          path: free[i].path,
          backlogRoot: backlogRoot,
        ),
    ];

    DateTime? recheckAt;
    for (final claim in liveClaims) {
      if (recheckAt == null || claim.expiresAt.isBefore(recheckAt)) recheckAt = claim.expiresAt;
    }

    return DispatchPlan(
      config: config,
      takenAt: snapshot.takenAt,
      worktrees: List.unmodifiable(worktrees),
      assignments: List.unmodifiable(assignments),
      waiting: List.unmodifiable(ready.skip(assignments.length)),
      recheckAt: recheckAt,
    );
  }

  final DispatcherConfig config;
  final DateTime takenAt;
  final List<WorktreeState> worktrees;

  /// What should start now, most urgent first.
  final List<DispatchAssignment> assignments;

  /// Ready items left over for lack of free worktrees or of the limit.
  final List<PlannedItem> waiting;

  /// The earliest expiry of a live claim: the plan may change then without
  /// any file changing (a worktree frees up, an item becomes ready).
  final DateTime? recheckAt;

  DispatchMode get mode => config.mode;

  /// Busy configured worktrees.
  int get running => worktrees.where((w) => w.isBusy).length;

  /// How many more agents may start (limit minus running, at least zero).
  int get capacity => (config.maxAgents - running).clamp(0, config.maxAgents);

  /// Same mode, same busy worktrees, same assignments and waiting items.
  bool sameDecisionAs(DispatchPlan? other) =>
      other != null &&
      other.mode == mode &&
      _sameList(other.assignments.map((a) => a.key), assignments.map((a) => a.key)) &&
      _sameList(other.waiting.map((i) => i.id), waiting.map((i) => i.id)) &&
      _sameList(other.worktrees.map((w) => '${w.name}:${w.isBusy}'), worktrees.map((w) => '${w.name}:${w.isBusy}'));

  static bool _sameList(Iterable<Object> a, Iterable<Object> b) =>
      const ListEquality<Object>().equals(a.toList(), b.toList());
}

/// Port for whatever starts an agent: claims [DispatchAssignment.id] under
/// [DispatchAssignment.agent] and runs the command in the worktree. It
/// should claim before it returns, so that the next plan already sees the
/// worktree busy; a `ClaimConflictException` just means someone was faster.
abstract interface class AgentLauncher {
  Future<void> launch(DispatchAssignment assignment);
}
