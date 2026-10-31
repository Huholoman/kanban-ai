import 'package:collection/collection.dart';

import '../../claims/domain/claim.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';

/// An agent process started by the dispatcher that is still running.
final class AgentRun {
  const AgentRun({
    required this.item,
    required this.worktree,
    required this.pid,
    required this.startedAt,
    required this.log,
    required this.agent,
    this.branch,
  });

  final ItemId item;

  /// Name of the worktree it runs in (also the name of its claim).
  final String worktree;
  final int pid;
  final DateTime startedAt;

  /// Absolute path of the file its output goes to.
  final String log;

  /// Name of the agent profile.
  final String agent;
  final String? branch;
}

/// The end of an agent's log file.
final class AgentLog {
  const AgentLog({required this.path, required this.lines, required this.running, this.last});

  final String path;

  /// The last lines of the file.
  final List<String> lines;

  /// The agent still runs; otherwise this is the log of its last run.
  final bool running;

  /// How the last run ended (`exit_code`, `reason`, `outcome`, `ended_at`,
  /// `session_id`); null while it runs.
  final Map<String, Object?>? last;
}

/// What the dispatcher knows beyond the backlog files, supplied by the
/// [AgentLauncher]: worktrees that cannot take work now, items it should
/// not start by itself, and the agents that are running.
final class DispatchConditions {
  const DispatchConditions({
    this.unavailable = const {},
    this.held = const {},
    this.runs = const [],
    this.created = const [],
    this.spare = const [],
  });

  static const none = DispatchConditions();

  /// Worktree name → why no agent can start there (uncommitted changes, not
  /// a git worktree, missing folder…).
  final Map<String, String> unavailable;

  /// Items that are ready but must not be started automatically (their last
  /// agent ended without finishing, or a person stopped it) → why. A manual
  /// start still works.
  final Map<ItemId, String> held;

  /// Agents running now.
  final List<AgentRun> runs;

  /// Worktrees the dispatcher created earlier (`dispatcher.repo`) that still
  /// exist; they join the listed ones.
  final List<WorktreeDefinition> created;

  /// Worktrees the dispatcher may create when none is free, in the order it
  /// would create them (within `max_worktrees`).
  final List<WorktreeDefinition> spare;
}

/// A configured worktree at the moment of planning.
final class WorktreeState {
  const WorktreeState(
    this.worktree,
    this.path,
    this.claims, {
    this.unavailable,
    this.run,
    this.created = false,
    this.isNew = false,
  });

  final WorktreeDefinition worktree;

  /// Absolute path of the worktree.
  final String path;

  /// Live claims held under the worktree's name (usually zero or one).
  final List<Claim> claims;

  /// Why no agent can start here now; null when nothing is wrong.
  final String? unavailable;

  /// The agent process running here, if any.
  final AgentRun? run;

  /// The dispatcher created it (`dispatcher.repo`) rather than finding it
  /// in `dispatcher.worktrees`.
  final bool created;

  /// It does not exist yet: the dispatcher creates it when its assignment
  /// starts.
  final bool isNew;

  String get name => worktree.name;

  /// An agent works here: some live claim is held under its name, or an
  /// agent process still runs in it.
  bool get isBusy => claims.isNotEmpty || run != null;

  /// An agent may start here now.
  bool get isFree => !isBusy && unavailable == null;
}

/// "Start [item] in [worktree]": the agent takes the claim under the
/// worktree's name and runs [command] inside [path] with [environment], on
/// [branch].
final class DispatchAssignment {
  const DispatchAssignment({
    required this.item,
    required this.worktree,
    required this.path,
    required this.agentProfile,
    required this.prompt,
    required this.command,
    this.environment = const {},
    this.branch,
    this.base,
    this.createFrom,
  });

  /// Fills the [config]'s prompt, command and environment for [item] in
  /// [worktree] (absolute [path]); [backlogRoot] is the backlog folder.
  factory DispatchAssignment.render(
    DispatcherConfig config, {
    required PlannedItem item,
    required WorktreeDefinition worktree,
    required String path,
    required String backlogRoot,
    bool create = false,
  }) {
    final branch = branchFor(item);
    final values = {
      'id': item.id.value,
      'title': item.item.title,
      'worktree': worktree.name,
      'path': path,
      'backlog': backlogRoot,
      'branch': branch,
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
      branch: branch,
      base: config.base,
      createFrom: create ? config.newWorktrees?.resolveRepo(backlogRoot) : null,
    );
  }

  /// The branch an agent works on for [item]: its `branch` field, else
  /// `agent/<id>`.
  static String branchFor(PlannedItem item) {
    final own = item.item.branch?.trim();
    return own == null || own.isEmpty ? 'agent/${item.id}' : own;
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

  /// The branch to check out in the worktree before the agent starts; null
  /// leaves the worktree as it is.
  final String? branch;

  /// Where [branch] starts when it does not exist yet (`dispatcher.base`).
  final String? base;

  /// The primary clone to add the worktree from (`git worktree add`) before
  /// the agent starts; null when the worktree exists.
  final String? createFrom;

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
    required this.snapshot,
    required this.backlogRoot,
    required this.worktrees,
    required this.assignments,
    required this.waiting,
    this.held = const [],
    this.spare = const [],
    this.recheckAt,
  });

  /// The plan for [snapshot], or null when its workflow has no dispatcher.
  /// Relative worktree paths are resolved against [backlogRoot].
  static DispatchPlan? of(
    BacklogSnapshot snapshot, {
    required String backlogRoot,
    DispatchConditions conditions = DispatchConditions.none,
  }) {
    final config = snapshot.workflow.dispatcher;
    if (config == null) return null;

    final liveClaims = [
      for (final planned in snapshot.items)
        if (planned.isClaimed) planned.claim!,
    ];
    final listed = {for (final worktree in config.worktrees) worktree.name};
    final worktrees = [
      for (final (worktree, created) in [
        for (final worktree in config.worktrees) (worktree, false),
        for (final worktree in conditions.created)
          if (!listed.contains(worktree.name)) (worktree, true),
      ])
        WorktreeState(
          worktree,
          worktree.resolvePath(backlogRoot),
          [
            for (final claim in liveClaims)
              if (claim.agent == worktree.name) claim,
          ],
          unavailable: conditions.unavailable[worktree.name],
          run: conditions.runs.firstWhereOrNull((run) => run.worktree == worktree.name),
          created: created,
        ),
    ];
    final spare = config.newWorktrees == null
        ? const <WorktreeState>[]
        : [
            for (final worktree in conditions.spare)
              WorktreeState(worktree, worktree.resolvePath(backlogRoot), const [], created: true, isNew: true),
          ];
    final running = worktrees.where((w) => w.isBusy).length;
    final free = [...worktrees.where((w) => w.isFree), ...spare];
    final slots = (config.maxAgents - running).clamp(0, free.length);
    final ready = snapshot.ready.where((item) => !conditions.held.containsKey(item.id)).toList();

    final assignments = <DispatchAssignment>[
      for (var i = 0; i < slots && i < ready.length; i++)
        DispatchAssignment.render(
          config,
          item: ready[i],
          worktree: free[i].worktree,
          path: free[i].path,
          backlogRoot: backlogRoot,
          create: free[i].isNew,
        ),
    ];
    // New worktrees show up in the plan once something would start there.
    worktrees.addAll(spare.where((w) => assignments.any((a) => a.worktree.name == w.name)));

    DateTime? recheckAt;
    for (final claim in liveClaims) {
      if (recheckAt == null || claim.expiresAt.isBefore(recheckAt)) recheckAt = claim.expiresAt;
    }

    return DispatchPlan(
      config: config,
      snapshot: snapshot,
      backlogRoot: backlogRoot,
      worktrees: List.unmodifiable(worktrees),
      assignments: List.unmodifiable(assignments),
      waiting: List.unmodifiable(ready.skip(assignments.length)),
      held: List.unmodifiable([
        for (final item in snapshot.ready)
          if (conditions.held[item.id] case final reason?) (item: item, reason: reason),
      ]),
      spare: List.unmodifiable(spare),
      recheckAt: recheckAt,
    );
  }

  final DispatcherConfig config;
  final BacklogSnapshot snapshot;
  final String backlogRoot;
  final List<WorktreeState> worktrees;

  /// What should start now, most urgent first.
  final List<DispatchAssignment> assignments;

  /// Ready items left over for lack of free worktrees or of the limit.
  final List<PlannedItem> waiting;

  /// Ready items the dispatcher does not start by itself, with the reason.
  final List<({PlannedItem item, String reason})> held;

  /// Worktrees the dispatcher may still create (`dispatcher.repo`), in the
  /// order it would; [WorktreeState.isNew].
  final List<WorktreeState> spare;

  /// The earliest expiry of a live claim: the plan may change then without
  /// any file changing (a worktree frees up, an item becomes ready).
  final DateTime? recheckAt;

  DateTime get takenAt => snapshot.takenAt;

  DispatchMode get mode => config.mode;

  /// Busy worktrees.
  int get running => worktrees.where((w) => w.isBusy).length;

  /// Worktrees an agent could start in now: free ones, then new ones.
  List<WorktreeState> get available => [...worktrees.where((w) => w.isFree && !w.isNew), ...spare];

  /// How many more agents may start (limit minus running, at least zero).
  int get capacity => (config.maxAgents - running).clamp(0, config.maxAgents);

  /// Some worktree cannot take work for a reason no file change reports.
  bool get hasUnavailable => worktrees.any((w) => w.unavailable != null);

  /// The assignment for starting [reference] by hand, now: the item must be
  /// ready (held items are fine) and a worktree free within `max_agents`.
  /// The first free worktree is used even when the plan gives it to a more
  /// urgent item.
  DispatchAssignment assignmentFor(String reference) {
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    if (!planned.isReady) throw _notReady(planned);
    final free = available;
    if (free.isEmpty || capacity == 0) {
      final reasons = [
        for (final worktree in worktrees)
          '${worktree.name}: ${worktree.isBusy ? 'busy' : worktree.unavailable ?? 'free'}',
        if (config.newWorktrees case final added? when spare.isEmpty)
          'no new worktree (max_worktrees ${added.maxWorktrees})',
      ];
      throw UnavailableException(
        'No free worktree for ${planned.id} ($running/${config.maxAgents} running; ${reasons.join('; ')}).',
      );
    }
    return DispatchAssignment.render(
      config,
      item: planned,
      worktree: free.first.worktree,
      path: free.first.path,
      backlogRoot: backlogRoot,
      create: free.first.isNew,
    );
  }

  BacklogException _notReady(PlannedItem planned) {
    final id = planned.id;
    if (planned.isClaimed) return ClaimConflictException('$id is claimed by ${planned.claim!.agent}.');
    final status = planned.item.status;
    final String why;
    if (planned.isDone) {
      why = 'it is $status';
    } else if (snapshot.workflow.status(status)?.pickable != true) {
      why = 'its status $status is not ${snapshot.workflow.pickableStatus}';
    } else if (planned.isBlocked) {
      why = 'it is blocked by ${[...planned.openDependencies, ...planned.missingDependencies].join(', ')}';
    } else if (planned.isConflicting) {
      why = 'it waits for ${planned.conflictsWith.join(', ')} (overlapping touches)';
    } else if (planned.openChildCount > 0) {
      why = 'it has ${planned.openChildCount} open child item(s)';
    } else {
      why = 'it cannot be picked up';
    }
    return InvalidInputException('$id is not ready: $why.');
  }

  /// Same mode, same busy and unavailable worktrees and running agents,
  /// same assignments, waiting and held items.
  bool sameDecisionAs(DispatchPlan? other) =>
      other != null &&
      other.mode == mode &&
      _sameList(other.assignments.map((a) => a.key), assignments.map((a) => a.key)) &&
      _sameList(other.waiting.map((i) => i.id), waiting.map((i) => i.id)) &&
      _sameList(other.held.map((h) => '${h.item.id}:${h.reason}'), held.map((h) => '${h.item.id}:${h.reason}')) &&
      _sameList(other.worktrees.map(_worktreeKey), worktrees.map(_worktreeKey));

  static String _worktreeKey(WorktreeState w) =>
      '${w.name}:${w.isBusy}:${w.unavailable}:${w.run?.item}:${w.run?.pid}:${w.isNew}';

  static bool _sameList(Iterable<Object> a, Iterable<Object> b) =>
      const ListEquality<Object>().equals(a.toList(), b.toList());
}

/// Port for whatever starts agents. [launch] claims
/// [DispatchAssignment.id] under [DispatchAssignment.agent] and runs the
/// command in the worktree; it should claim before it returns, so that the
/// next plan already sees the worktree busy (a `ClaimConflictException` just
/// means someone was faster). The other members have neutral defaults for
/// launchers that do not track processes.
abstract class AgentLauncher {
  Future<void> launch(DispatchAssignment assignment);

  /// Running agents, worktrees that cannot take work and held items for a
  /// plan of [snapshot] (whose workflow has the dispatcher [config]).
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async =>
      DispatchConditions.none;

  /// Stops the agent working on [item]; false when none runs.
  Future<bool> stop(ItemId item) async => false;

  /// The last [lines] lines of the log of the agent running for [item], or
  /// of its last run; null when there is none.
  Future<AgentLog?> agentLog(ItemId item, {int lines = 100}) async => null;

  /// Starts background work (watching processes); [onChange] is called when
  /// something the plan depends on changed outside the backlog files.
  void attach(void Function() onChange) {}

  Future<void> close() async {}
}
