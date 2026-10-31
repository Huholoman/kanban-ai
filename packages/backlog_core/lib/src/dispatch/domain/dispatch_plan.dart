import 'package:collection/collection.dart';

import '../../claims/domain/claim.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/planned_item.dart';
import '../../planning/domain/review_state.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/action_definition.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../../workflow/domain/workflow.dart';
import 'action_run.dart';
import 'agent_log_format.dart';
import 'agent_session.dart';

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
    this.action,
    this.kind = RunKind.agent,
  });

  final ItemId item;

  /// Name of the worktree it runs in (also the name of its claim); for an
  /// action's command outside the worktrees, the folder name of the primary
  /// clone.
  final String worktree;

  /// The action it runs for; null for the dispatcher's own agents.
  final String? action;

  /// An agent, or an action's command or built-in.
  final RunKind kind;
  final int pid;
  final DateTime startedAt;

  /// Absolute path of the file its output goes to.
  final String log;

  /// Name of the agent profile (the action's name for commands and
  /// built-ins).
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
    this.blocked = const {},
    this.runs = const [],
    this.sessions = const {},
    this.starts = const {},
    this.created = const [],
    this.spare = const [],
    this.branches = const {},
    this.pending = const [],
  });

  static const none = DispatchConditions();

  /// Worktree name → why no agent can start there (uncommitted changes, not
  /// a git worktree, missing folder…).
  final Map<String, String> unavailable;

  /// Items that are ready but must not be started automatically (their last
  /// agent ended without finishing, or a person stopped it) → why. A manual
  /// start still works.
  final Map<ItemId, String> held;

  /// Held items that a person's reply does not start either: their branch
  /// is checked out in another worktree the dispatcher cannot free, so the
  /// start would fail. A manual start still tries.
  final Set<ItemId> blocked;

  /// Agents running now.
  final List<AgentRun> runs;

  /// The session of the last run per item, where the agent reported one.
  final Map<ItemId, AgentSession> sessions;

  /// When and where the last run of the item's own agent started, per
  /// unfinished item, whether or not it reported a session
  /// (`<id>.last.json`): replies are the comments written since.
  final Map<ItemId, AgentStart> starts;

  /// Worktrees the dispatcher created earlier (`dispatcher.repo`) that still
  /// exist; they join the listed ones.
  final List<WorktreeDefinition> created;

  /// Worktrees the dispatcher may create when none is free, in the order it
  /// would create them (within `max_worktrees`).
  final List<WorktreeDefinition> spare;

  /// Worktree name → the branch checked out there, for worktrees that are
  /// not busy (where an item's actions run).
  final Map<String, String> branches;

  /// `on_enter` actions waiting to run.
  final List<PendingAction> pending;

  /// These conditions with [pending] in place of the current ones.
  DispatchConditions withPending(List<PendingAction> pending) => DispatchConditions(
    unavailable: unavailable,
    held: held,
    blocked: blocked,
    runs: runs,
    sessions: sessions,
    starts: starts,
    created: created,
    spare: spare,
    branches: branches,
    pending: pending,
  );
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
    this.resume,
    this.createFrom,
    this.action,
    this.trigger = ActionTrigger.request,
    this.fix,
    this.newSession = false,
  });

  /// Fills the [config]'s prompt, command and environment for [item] in
  /// [worktree] (absolute [path]); [backlogRoot] is the backlog folder. With
  /// [resume] (a session the profile can continue there, see
  /// [AgentSession.resumableBy]) the agent continues it with the resume
  /// prompt instead of starting a new session. Without one, [replies] (the
  /// `{news}` of a new session started for replies, see [newSessionNews])
  /// also selects the resume prompt.
  ///
  /// With a prompt [action] the agent is the action's profile and its prompt
  /// is the action's text inside [actionFrame]; it continues [resume] the
  /// same way.
  factory DispatchAssignment.render(
    DispatcherConfig config, {
    required PlannedItem item,
    required WorktreeDefinition worktree,
    required String path,
    required String backlogRoot,
    AgentSession? resume,
    bool create = false,
    ActionDefinition? action,
    ActionTrigger trigger = ActionTrigger.request,
    ReviewFix? fix,
    String? replies,
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
    final profile = action == null ? config.agent : config.profileFor(action);
    final session = resume != null && resume.resumableBy(profile, worktree.name) ? resume : null;
    final news = session?.news(session.commentsIn(item.item));
    final String prompt;
    if (fix != null) {
      prompt = fixFrame.render({
        ...values,
        'status': item.item.status,
        'context': session == null
            ? 'Run `backlog instructions` and `backlog show ${item.id}` first.'
            : 'You continue your earlier session on this item; run `backlog show ${item.id}` to see it as it is now.',
        'round': '${fix.round}',
        'rounds': '${fix.rounds}',
        'publish': config.pr == null
            ? 'Never push.'
            : 'Publish your commits with `backlog pr ${item.id}` (it pushes your branch and updates the pull '
                  'request); never run `git push`.',
        'reviewer': fix.review.author,
        'reviewed': fix.review.commit == null ? 'no commit named' : 'of commit ${fix.review.commit}',
        'review': fix.review.text,
      });
    } else if (action == null) {
      prompt = session != null
          ? config.resumePrompt.render({...values, 'news': news!})
          : replies != null
          ? config.resumePrompt.render({...values, 'news': replies})
          : config.prompt.render(values);
    } else {
      final actionValues = {
        ...values,
        'pr': item.item.pr ?? '',
        'status': item.item.status,
        'base': config.base,
        'action': action.name,
        'news': news ?? 'This is a new session.',
      };
      prompt = actionFrame.render({
        ...actionValues,
        'context': session == null
            ? 'Run `backlog show ${item.id}` first to see the item and its discussion.'
            : 'You continue your earlier session on this item. Since your last run: $news\n'
                  'Run `backlog show ${item.id}` to see the item as it is now.',
        'task': action.review
            ? ActionDefinition.reviewTask(actionValues, extra: action.prompt?.render(actionValues))
            : action.prompt!.render(actionValues),
        'finish': action.review
            ? 'When you are done, record your verdict with `backlog review` as described (that is your one '
                  'comment) and stop.'
            : 'Comment only when the action asks you to (then in exactly one comment) or to answer a question a '
                  'person asked; otherwise finish without a comment.',
        'publish': action.review
            ? 'Never push.'
            : config.pr == null
            ? 'Never push.'
            : 'Never run `git push`: to publish your commits run `backlog pr ${item.id}` (it pushes your branch '
                  'and updates the item\'s pull request).',
      });
    }
    final full = {...values, 'prompt': prompt, 'session': ?session?.id};
    return DispatchAssignment(
      item: item,
      worktree: worktree,
      path: path,
      agentProfile: profile,
      prompt: prompt,
      command: [...profile.command.render(full), if (session != null) ...profile.resume!.render(full)],
      environment: {
        ...headlessGit,
        'BACKLOG_AGENT': worktree.name,
        'BACKLOG_DIR': backlogRoot,
        for (final MapEntry(:key, :value) in profile.environment.entries) key: value.render(full),
      },
      branch: branch,
      base: config.base,
      resume: session,
      createFrom: create ? config.newWorktrees?.resolveRepo(backlogRoot) : null,
      action: action,
      trigger: trigger,
      fix: fix,
      newSession: session == null && replies != null && action == null && fix == null,
    );
  }

  /// What the item's agent is told when an AI review with `auto_fix` asks
  /// for changes: fix the findings of the review (`{review}`), comment only
  /// on findings left unfixed, publish (`{publish}`), set the status again
  /// and stop; the talking and running rules follow.
  static final fixFrame = TextTemplate(
    'You are the agent {worktree} on backlog item {id} ("{title}") in this git worktree, on branch {branch}. The '
    'item is claimed for you (BACKLOG_AGENT={worktree}) while you work; it stays in status {status}.\n'
    '{context}\n\n'
    'An AI review of your work asks for changes (automatic fix round {round} of {rounds}). Fix its findings '
    'below in small commits whose messages contain {id}. Where a finding is wrong, do not change the code; say '
    'why in exactly one comment (`backlog comment {id} "…"`); what you fixed belongs in the commit messages, not '
    'in a comment. {publish} Then run `backlog set {id} status={status}` and stop. If something is unclear, ask '
    'with `backlog ask {id} "<your question>"` and stop.\n'
    '${DispatcherConfig.checklistRules}\n${DispatcherConfig.talkRules}\n${DispatcherConfig.runRules}\n\n'
    'The review by {reviewer} ({reviewed}):\n\n{review}',
    known: const [
      ...DispatcherConfig.promptPlaceholders,
      'status',
      'context',
      'round',
      'rounds',
      'publish',
      'reviewer',
      'reviewed',
      'review',
    ],
    label: 'fix prompt',
  );

  /// What the agent of a prompt action is told: who and where it is, that
  /// the item keeps its status, the item's context, the action's text
  /// (`{task}`, for a review the built-in review task), how to finish
  /// (`{finish}`: `backlog comment`, a review `backlog review`) and how it
  /// may publish commits (`{publish}`: `backlog pr` with `dispatcher.pr`,
  /// else — and always for a review — never push).
  static final actionFrame = TextTemplate(
    'You are the agent {worktree}, started for the action "{action}" on backlog item {id} ("{title}") in this '
    'git worktree, on branch {branch}. The item is claimed for you (BACKLOG_AGENT={worktree}) only while the '
    'action runs; it stays in status {status} unless the action asks you to change it (never set it to '
    'in-progress), and you take no other items.\n'
    '{context}\n\n'
    'The action:\n{task}\n\n'
    '{finish} If something is unclear, ask with `backlog ask {id} "<your question>"` and stop. {publish}\n'
    '${DispatcherConfig.checklistRules}\n${DispatcherConfig.talkRules}\n${DispatcherConfig.runRules}',
    known: const [...ActionDefinition.promptPlaceholders, 'context', 'task', 'finish', 'publish'],
    label: 'action prompt',
  );

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

  /// Set for the agent on top of the server's environment: [headlessGit],
  /// `BACKLOG_AGENT` (the worktree name), `BACKLOG_DIR` (the backlog folder)
  /// and the profile's `env` (which may replace any of them).
  final Map<String, String> environment;

  /// Git never opens an editor for agents and action commands, which nobody
  /// could use (`git rebase --continue`, `git commit` without `-m`).
  static const headlessGit = {'GIT_EDITOR': 'true', 'GIT_SEQUENCE_EDITOR': 'true'};

  /// The branch to check out in the worktree before the agent starts; null
  /// leaves the worktree as it is.
  final String? branch;

  /// Where [branch] starts when it does not exist yet (`dispatcher.base`).
  final String? base;

  /// The earlier session the agent continues; null for a new session.
  final AgentSession? resume;

  /// The primary clone to add the worktree from (`git worktree add`) before
  /// the agent starts; null when the worktree exists.
  final String? createFrom;

  /// The prompt action the agent runs for; null for the item's own work.
  /// Such an agent takes the claim without changing the item (status,
  /// assignee), never lifts or causes a hold and loses the claim at the end.
  final ActionDefinition? action;

  /// Why the [action] runs.
  final ActionTrigger trigger;

  /// The item's own agent is woken to fix the findings of an AI review
  /// (`auto_fix`); null otherwise.
  final ReviewFix? fix;

  /// A new session takes up replies to the item's agent because none can be
  /// continued ([DispatchPlan.hasRepliesWithoutSession]).
  final bool newSession;

  ItemId get id => item.id;

  /// The name the claim is taken under.
  String get agent => worktree.name;

  /// `<id>@<worktree>` (with `+resume` when continuing a session); equal
  /// keys mean the same decision.
  String get key =>
      '$id@${worktree.name}${resume == null ? '' : '+resume'}${newSession ? '+reply' : ''}'
      '${action == null ? '' : ':${action!.name}'}'
      '${fix == null ? '' : '+fix'}';
}

/// Round [round] of [rounds] (`auto_fix`) of fixing the findings of the AI
/// [review].
final class ReviewFix {
  const ReviewFix({required this.review, required this.round, required this.rounds});

  final Comment review;
  final int round;
  final int rounds;
}

/// What the dispatcher would do with one [BacklogSnapshot]: which ready items
/// go to which free worktrees, within the limit of concurrent agents.
///
/// Pure and deterministic: ready items in the order of `backlog next`
/// (priority, age, id), free worktrees in the configured order.
extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

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
    this.sessions = const {},
    this.starts = const {},
    this.runs = const [],
    this.pending = const [],
    this.branches = const {},
    this.waitingReasons = const {},
  });

  /// Whether a person (anyone but the agent) commented on unfinished,
  /// unclaimed [planned] since its last agent [session] started, and
  /// [config]'s agent can continue that session: the dispatcher then
  /// resumes it with the comments, whatever the item's status and hold.
  static bool hasReplies(PlannedItem planned, AgentSession? session, DispatcherConfig config) =>
      session != null &&
      !planned.isDone &&
      !planned.isClaimed &&
      !planned.needsHuman &&
      session.resumableBy(config.agent, session.worktree) &&
      session.repliesIn(planned.item).isNotEmpty;

  /// Whether others commented on unfinished, unclaimed [planned] for its
  /// agent ([repliesWithoutSession] since its last [start]) but [config]'s
  /// agent cannot continue its [session] (none is known, it ran elsewhere,
  /// another profile): a new session of the agent takes the comments up,
  /// like a resume would, whatever the item's status and hold.
  static bool hasRepliesWithoutSession(
    PlannedItem planned,
    AgentSession? session,
    AgentStart? start,
    BacklogSnapshot snapshot,
    DispatcherConfig config,
  ) =>
      !planned.isDone &&
      !planned.isClaimed &&
      !planned.needsHuman &&
      !(session != null && session.resumableBy(config.agent, session.worktree)) &&
      repliesWithoutSession(
        planned.item,
        start,
        active: snapshot.workflow.categoryOf(planned.item.status) == StatusCategory.active,
      ).isNotEmpty;

  /// The `{news}` of a new session for [planned]'s replies
  /// ([hasRepliesWithoutSession]); null when it has none.
  String? _newSessionNews(PlannedItem planned) =>
      hasRepliesWithoutSession(planned, sessions[planned.id], starts[planned.id], snapshot, config)
      ? newSessionNews(
          repliesWithoutSession(
            planned.item,
            starts[planned.id],
            active: snapshot.workflow.categoryOf(planned.item.status) == StatusCategory.active,
            notes: true,
          ),
        )
      : null;

  /// Whether [assignment] continues a session because a person replied to
  /// its agent ([hasReplies]) or starts a new one for such replies
  /// ([hasRepliesWithoutSession]): such starts run in manual mode too.
  bool isReply(DispatchAssignment assignment) {
    final planned = snapshot[assignment.id];
    if (planned == null || assignment.action != null || assignment.fix != null) return false;
    if (assignment.resume != null) return hasReplies(planned, sessions[assignment.id], config);
    return assignment.newSession &&
        hasRepliesWithoutSession(planned, sessions[assignment.id], starts[assignment.id], snapshot, config);
  }

  /// The free, existing worktree in [free] where [config]'s agent can
  /// continue [session]; a new worktree never holds a session.
  static WorktreeState? _resumableIn(AgentSession? session, AgentProfile profile, List<WorktreeState> free) =>
      session == null ? null : free.firstWhereOrNull((w) => !w.isNew && session.resumableBy(profile, w.name));

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
    // A session can only go on in its own worktree. When that worktree is
    // gone (a created one removed by hand or cleaned up), the session is
    // forgotten and the next start is a new session; a listed worktree that
    // is missing just stays unavailable, so its sessions wait for it.
    final existing = {for (final worktree in worktrees) worktree.name};
    final sessions = {
      for (final MapEntry(:key, :value) in conditions.sessions.entries)
        if (existing.contains(value.worktree)) key: value,
    };
    final running = worktrees.where((w) => w.isBusy).length;
    final free = [...worktrees.where((w) => w.isFree), ...spare];
    final slots = (config.maxAgents - running).clamp(0, free.length);
    final runningItems = {for (final run in conditions.runs) run.item};
    // A person wrote to an agent: first, even when held (unless its branch is
    // stuck in another worktree). Its session goes on, or without one a new
    // session takes the comments up.
    final fresh = {
      for (final planned in snapshot.items)
        if (!runningItems.contains(planned.id) &&
            !conditions.blocked.contains(planned.id) &&
            hasRepliesWithoutSession(planned, sessions[planned.id], conditions.starts[planned.id], snapshot, config))
          planned.id,
    };
    final replied = [
      for (final planned in snapshot.items)
        if (fresh.contains(planned.id) ||
            (!runningItems.contains(planned.id) &&
                !conditions.blocked.contains(planned.id) &&
                hasReplies(planned, sessions[planned.id], config)))
          planned,
    ];
    final ready = [
      ...replied,
      for (final item in snapshot.ready)
        if (!conditions.held.containsKey(item.id) && !replied.contains(item) && !runningItems.contains(item.id)) item,
    ];

    final waitingForAnswer = [
      for (final planned in snapshot.items)
        if (planned.needsHuman && !planned.isDone && sessions.containsKey(planned.id)) planned,
    ];

    final assignments = <DispatchAssignment>[];
    final left = <PlannedItem>[];
    final reasons = <ItemId, String>{};
    // In manual mode the assignments are only proposals: they reserve
    // nothing, so an item they leave out can still be started by hand
    // ([assignmentFor]) while an agent may start at all.
    final proposalsOnly = config.mode == DispatchMode.manual && slots > 0;
    final unproposed = [...free];
    for (final (index, candidate) in ready.indexed) {
      final session = sessions[candidate.id];
      final newSession = fresh.contains(candidate.id);
      final full = free.isEmpty || assignments.length >= slots;
      final own = _resumableIn(session, config.agent, full && proposalsOnly ? unproposed : free);
      final String? reason;
      if (full && !proposalsOnly) {
        reason = free.isEmpty || config.maxAgents - running > assignments.length
            ? 'no free worktree'
            : 'max_agents (${config.maxAgents}) reached';
      } else if (own == null && !candidate.isReady && !newSession) {
        reason = 'the worktree ${session!.worktree} of its session is not free'; // a reply waits for it
      } else {
        reason = null;
      }
      if (reason != null || full) {
        left.add(candidate);
        if (reason != null) reasons[candidate.id] = reason;
        continue;
      }
      // Leave the worktrees that later items could continue their sessions in
      // to them, and those of agents waiting for an answer to their question.
      final reserved = {
        for (final later in [...ready.skip(index + 1), ...waitingForAnswer])
          if (_resumableIn(sessions[later.id], config.agent, free) case final w?) w.name,
      };
      // A new session for replies goes where the item's branch is checked out.
      final branch = DispatchAssignment.branchFor(candidate);
      final home = newSession ? free.firstWhereOrNull((w) => !w.isNew && conditions.branches[w.name] == branch) : null;
      final target = own ?? home ?? free.firstWhere((w) => !reserved.contains(w.name), orElse: () => free.first);
      free.remove(target);
      assignments.add(
        DispatchAssignment.render(
          config,
          item: candidate,
          worktree: target.worktree,
          path: target.path,
          backlogRoot: backlogRoot,
          resume: own == null ? null : session,
          create: target.isNew,
          replies: newSession
              ? newSessionNews(
                  repliesWithoutSession(
                    candidate.item,
                    conditions.starts[candidate.id],
                    active: snapshot.workflow.categoryOf(candidate.item.status) == StatusCategory.active,
                    notes: true,
                  ),
                )
              : null,
        ),
      );
    }
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
      waiting: List.unmodifiable(left),
      waitingReasons: Map.unmodifiable(reasons),
      sessions: Map.unmodifiable(sessions),
      starts: Map.unmodifiable(conditions.starts),
      held: List.unmodifiable([
        for (final item in snapshot.ready)
          if (conditions.held[item.id] case final reason? when !replied.contains(item)) (item: item, reason: reason),
      ]),
      spare: List.unmodifiable(spare),
      recheckAt: recheckAt,
      runs: List.unmodifiable(conditions.runs),
      pending: List.unmodifiable(conditions.pending),
      branches: Map.unmodifiable(conditions.branches),
    );
  }

  final DispatcherConfig config;
  final BacklogSnapshot snapshot;
  final String backlogRoot;
  final List<WorktreeState> worktrees;

  /// What should start now: items with replies for their agent first
  /// ([hasReplies]), then ready ones, most urgent first.
  final List<DispatchAssignment> assignments;

  /// Ready items left over for lack of free worktrees or of the limit, and
  /// items with replies for their agent ([hasReplies],
  /// [hasRepliesWithoutSession]) that cannot start yet.
  final List<PlannedItem> waiting;

  /// Why each of [waiting] cannot start now (`no free worktree`, …). In
  /// manual mode only items that cannot start even by hand have one: the
  /// proposals of other items take no worktree.
  final Map<ItemId, String> waitingReasons;

  /// Ready items the dispatcher does not start by itself, with the reason.
  final List<({PlannedItem item, String reason})> held;

  /// Worktrees the dispatcher may still create (`dispatcher.repo`), in the
  /// order it would; [WorktreeState.isNew].
  final List<WorktreeState> spare;

  /// The earliest expiry of a live claim: the plan may change then without
  /// any file changing (a worktree frees up, an item becomes ready).
  final DateTime? recheckAt;

  /// The session of each item's last agent run, where one is known and its
  /// worktree still exists.
  final Map<ItemId, AgentSession> sessions;

  /// The last start of each item's own agent ([DispatchConditions.starts]).
  final Map<ItemId, AgentStart> starts;

  /// Everything running now: agents (also those of prompt actions) and the
  /// commands and built-ins of actions, inside the worktrees or not.
  final List<AgentRun> runs;

  /// `on_enter` actions waiting to run.
  final List<PendingAction> pending;

  /// Worktree name → its checked-out branch (worktrees that are not busy).
  final Map<String, String> branches;

  /// What runs for [id] now, if anything.
  AgentRun? runFor(ItemId id) => runs.firstWhereOrNull((run) => run.item == id);

  /// Items an AI review ([ActionDefinition.review]) runs or waits to run
  /// for.
  Set<ItemId> get reviewing => {
    for (final run in runs)
      if (run.action != null && config.action(run.action!)?.review == true) run.item,
    for (final waiting in pending)
      if (config.action(waiting.action)?.review == true) waiting.item,
  };

  /// [planned]'s review state with what the dispatcher knows:
  /// [ReviewState.running] while a review runs or waits to run for it.
  ReviewState reviewOf(PlannedItem planned) => reviewing.contains(planned.id) ? ReviewState.running : planned.review;

  /// The actions that items in [planned]'s status offer as buttons.
  List<ActionDefinition> actionsFor(PlannedItem planned) => [
    for (final action in config.actions)
      if (action.offeredIn(planned.item.status)) action,
  ];

  /// What starting the action [name] on [reference] runs now: an agent for
  /// a prompt action, otherwise an [ActionJob] (exactly one is set).
  ///
  /// Nothing else may run for the item. A person ([ActionTrigger.request])
  /// may only start actions the item's status offers. A prompt action
  /// needs a worktree within `max_agents`: it continues the item's last
  /// session in its worktree unless the action is `fresh`, else it prefers
  /// the free worktree that has the item's branch checked out, then the
  /// worktree of the item's session, then any free (or new) one. A command
  /// or built-in runs in the free worktree that has the item's branch
  /// checked out, else in the primary clone (`dispatcher.repo`); a command
  /// without either cannot run (a built-in then runs in the backlog folder).
  ({DispatchAssignment? agent, ActionJob? job}) actionStart(
    String reference,
    String name, {
    ActionTrigger trigger = ActionTrigger.request,
    String? from,
  }) {
    final action =
        config.action(name) ??
        (throw NotFoundException(
          'No action "$name" (configured: ${config.actions.map((a) => a.name).join(', ').ifEmpty('none')}).',
        ));
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    final id = planned.id;
    final status = planned.item.status;
    if (trigger == ActionTrigger.request && !action.offeredIn(status)) {
      throw InvalidInputException('The action "$name" is not offered for items in $status.');
    }
    if (runFor(id) case final run?) {
      throw UnavailableException(
        '${run.action == null ? 'An agent' : 'The action "${run.action}"'} already runs for $id '
        '(in ${run.worktree}); try again when it has ended.',
      );
    }
    final branch = DispatchAssignment.branchFor(planned);
    final home = worktrees.firstWhereOrNull((w) => !w.isBusy && !w.isNew && branches[w.name] == branch);

    if (action.kind == ActionKind.prompt) {
      if (planned.isClaimed) throw ClaimConflictException('$id is claimed by ${planned.claim!.agent}.');
      final free = available;
      if (free.isEmpty || capacity == 0) {
        throw UnavailableException(
          'No free worktree for the action "$name" on $id ($running/${config.maxAgents} running).',
        );
      }
      final profile = config.profileFor(action);
      final session = sessions[id];
      final own = action.fresh ? null : _resumableIn(session, profile, free);
      bool isFree(String? worktree) => free.any((w) => w.name == worktree && !w.isNew);
      final target =
          own ??
          free.firstWhereOrNull((w) => w.name == home?.name) ??
          free.firstWhereOrNull((w) => isFree(session?.worktree) && w.name == session!.worktree) ??
          free.first;
      return (
        agent: DispatchAssignment.render(
          config,
          item: planned,
          worktree: target.worktree,
          path: target.path,
          backlogRoot: backlogRoot,
          resume: own == null ? null : session,
          create: target.isNew,
          action: action,
          trigger: trigger,
        ),
        job: null,
      );
    }

    final repo = config.newWorktrees?.resolveRepo(backlogRoot);
    final path =
        home?.path ??
        repo ??
        (action.kind == ActionKind.builtIn
            ? backlogRoot
            : throw UnavailableException(
                'The action "$name" runs in the worktree of $id, but no free dispatcher worktree has its branch '
                '$branch checked out (and dispatcher.repo is not set).',
              ));
    final values = {
      'id': id.value,
      'title': planned.item.title,
      'branch': branch,
      'pr': planned.item.pr ?? '',
      'status': status,
      'worktree': home?.name ?? '',
      'path': path,
      'backlog': backlogRoot,
      'base': config.base,
      'action': action.name,
    };
    return (
      agent: null,
      job: ActionJob(
        item: planned,
        action: action,
        trigger: trigger,
        from: from,
        worktree: home?.name,
        path: path,
        values: values,
        command: action.command?.render(values),
        environment: {
          ...DispatchAssignment.headlessGit,
          'BACKLOG_DIR': backlogRoot,
          'BACKLOG_AGENT': ?home?.name,
          'KANBAN_AI_ITEM': id.value,
          'KANBAN_AI_ACTION': action.name,
        },
      ),
    );
  }

  /// The item's own agent, woken to fix the findings of an AI [review]
  /// (`auto_fix` round [round] of [rounds]): it continues the item's
  /// session in its worktree when it can, else starts a new one where the
  /// item's branch is checked out, else in any free (or new) worktree.
  /// Fails with `UnavailableException` while something runs for the item or
  /// no worktree is free, `ClaimConflictException` when it is claimed.
  DispatchAssignment fixStart(ItemId id, {required Comment review, required int round, required int rounds}) {
    final planned = snapshot[id] ?? (throw NotFoundException('No item $id.'));
    if (runFor(id) case final run?) {
      throw UnavailableException('${run.action ?? 'An agent'} already runs for $id.');
    }
    if (planned.isClaimed) throw ClaimConflictException('$id is claimed by ${planned.claim!.agent}.');
    final free = available;
    if (free.isEmpty || capacity == 0) {
      throw UnavailableException('No free worktree to fix the review of $id ($running/${config.maxAgents} running).');
    }
    final session = sessions[id];
    final own = _resumableIn(session, config.agent, free);
    final branch = DispatchAssignment.branchFor(planned);
    final target = own ?? free.firstWhereOrNull((w) => !w.isNew && branches[w.name] == branch) ?? free.first;
    return DispatchAssignment.render(
      config,
      item: planned,
      worktree: target.worktree,
      path: target.path,
      backlogRoot: backlogRoot,
      resume: own == null ? null : session,
      create: target.isNew,
      fix: ReviewFix(review: review, round: round, rounds: rounds),
    );
  }

  /// The session a start of [id] would continue with the configured agent
  /// (in its own worktree); null when it would start a new one.
  AgentSession? resumableSession(ItemId id) {
    final session = sessions[id];
    return session != null && session.resumableBy(config.agent, session.worktree) ? session : null;
  }

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
  /// ready (held items are fine) or have replies for its agent
  /// ([hasReplies]), and a worktree free within `max_agents`. The agent
  /// continues the item's last session when it can (in the worktree of that
  /// session, if free), unless [fresh]; otherwise the first free worktree is
  /// used even when the plan gives it to a more urgent item.
  DispatchAssignment assignmentFor(String reference, {bool fresh = false}) {
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    final replied = !fresh && hasReplies(planned, sessions[planned.id], config);
    final news = fresh ? null : _newSessionNews(planned);
    if (!planned.isReady && !replied && news == null) throw _notReady(planned);
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
    final session = fresh ? null : sessions[planned.id];
    final own = _resumableIn(session, config.agent, free);
    if (own == null && !planned.isReady && news == null) {
      throw UnavailableException(
        'The worktree ${session!.worktree} of the session of ${planned.id} is not free; '
        'its agent continues there once it is.',
      );
    }
    final branch = DispatchAssignment.branchFor(planned);
    final home = news == null ? null : free.firstWhereOrNull((w) => !w.isNew && branches[w.name] == branch);
    final target = own ?? home ?? free.first;
    return DispatchAssignment.render(
      config,
      item: planned,
      worktree: target.worktree,
      path: target.path,
      backlogRoot: backlogRoot,
      resume: own == null ? null : session,
      create: target.isNew,
      replies: own == null ? news : null,
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
    } else if (planned.needsHuman) {
      why = 'it waits for a person to answer the question of ${planned.item.discussion.openQuestion!.author}';
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
      _sameList(
        other.waiting.map((i) => '${i.id}:${other.waitingReasons[i.id]}'),
        waiting.map((i) => '${i.id}:${waitingReasons[i.id]}'),
      ) &&
      _sameList(other.held.map((h) => '${h.item.id}:${h.reason}'), held.map((h) => '${h.item.id}:${h.reason}')) &&
      _sameList(other.worktrees.map(_worktreeKey), worktrees.map(_worktreeKey)) &&
      _sameList(other.runs.map(_runKey), runs.map(_runKey)) &&
      _sameList(other.pending.map(_pendingKey), pending.map(_pendingKey));

  static String _runKey(AgentRun run) => '${run.item}:${run.worktree}:${run.pid}:${run.action}';

  static String _pendingKey(PendingAction action) => '${action.item}:${action.action}:${action.status}';

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

  /// Runs the command or built-in of an action ([ActionJob]); like
  /// [launch] it returns once the job is recorded as running.
  Future<void> runJob(ActionJob job) async => throw const UnavailableException('This dispatcher cannot run actions.');

  /// Stops the agent working on [item]; false when none runs.
  Future<bool> stop(ItemId item) async => false;

  /// The last [lines] lines of the log of the agent running for [item], or
  /// of its last run; null when there is none.
  Future<AgentLog?> agentLog(ItemId item, {int lines = 100}) async => null;

  /// Where the log of the agent running for [item] is, else that of its
  /// last run; null when there is none. For following a log as it grows.
  Future<AgentLogSource?> agentLogSource(ItemId item) async => null;

  /// Starts background work (watching processes); [onChange] is called when
  /// something the plan depends on changed outside the backlog files.
  void attach(void Function() onChange) {}

  Future<void> close() async {}
}
