import 'package:collection/collection.dart';

import '../../claims/domain/claim.dart';
import '../../history/domain/item_history.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item_id.dart';
import '../../planning/domain/backlog_snapshot.dart';
import '../../planning/domain/epic_plan.dart';
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
    this.epic = false,
    this.milestone,
  });

  final ItemId item;

  /// The item's own agent implements it as an epic: all items under it on
  /// its branch ([DispatchAssignment.epic]).
  final bool epic;

  /// The milestone an [epic] run implements ([DispatchAssignment.milestone]);
  /// null for all of the epic.
  final String? milestone;

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
  /// `session_id`, `result`, `problems`); null while it runs.
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
    this.problems = const {},
    this.epics = const {},
    this.epicMilestones = const {},
    this.queue = const [],
  });

  static const none = DispatchConditions();

  /// Starts people asked for that wait ([QueuedStart]), oldest first.
  final List<QueuedStart> queue;

  /// Unfinished items whose own agent runs, or last ran, as the
  /// implementation of the whole epic ([DispatchAssignment.epic]): the items
  /// under them belong to that agent.
  final Set<ItemId> epics;

  /// The milestone each of [epics] is implemented for, when its run was
  /// limited to one ([EpicPlan.milestone]).
  final Map<ItemId, String> epicMilestones;

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

  /// Unfinished items whose latest run (of their agent or an action) ended
  /// with problems → what went wrong (a failed exit, denied permissions, a
  /// pull request that could not be opened, …).
  final Map<ItemId, List<String>> problems;

  /// These conditions with [pending] and [queue] in place of the current
  /// ones.
  DispatchConditions withPending(List<PendingAction> pending, {List<QueuedStart>? queue}) => DispatchConditions(
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
    problems: problems,
    epics: epics,
    epicMilestones: epicMilestones,
    queue: queue ?? this.queue,
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
    this.setup = const [],
    this.action,
    this.trigger = ActionTrigger.request,
    this.fix,
    this.newSession = false,
    this.epic = false,
    this.milestone,
    this.repair = false,
    this.returnTo,
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
  ///
  /// With [epic] the item's own agent implements all items under it, one
  /// after another, on the item's branch; its prompt is [epicFrame] (also
  /// when it continues a session or takes up replies). With [repair] (an
  /// epic whose items are all handed over or done, see
  /// [DispatchPlan.isRepair]) it is the epic's agent too, but its prompt is
  /// [repairFrame]: take up the replies on the epic's branch (typically a
  /// rebase after a failed merge) without taking items. A [milestone] limits
  /// the epic's agent to the items of that milestone (`backlog epic
  /// --milestone`).
  ///
  /// The item's own agent and the agent of an action that changes code
  /// ([ActionDefinition.changesCode]) work on an item handed over before
  /// (a later active status than [Workflow.activeStatus], e.g. `review`) in
  /// the active status; [returnTo] is where it came from (also
  /// `{handover}`).
  factory DispatchAssignment.render(
    DispatcherConfig config, {
    required Workflow workflow,
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
    bool epic = false,
    String? milestone,
    bool repair = false,
  }) {
    repair = repair && action == null && fix == null;
    epic = (epic || repair) && action == null && fix == null;
    if (!epic) milestone = null;
    final scope = milestone == null ? '' : ' --milestone $milestone';
    final branch = branchFor(item);
    final status = item.item.status;
    final returnTo =
        (action == null || action.changesCode) &&
            item.category == StatusCategory.active &&
            status != workflow.activeStatus
        ? status
        : null;
    final values = {
      'id': item.id.value,
      'title': item.item.title,
      'worktree': worktree.name,
      'path': path,
      'backlog': backlogRoot,
      'branch': branch,
      'handover': returnTo ?? config.handover,
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
        'decide': fix.then == null
            ? ''
            : ' If a finding needs a person\'s decision or you are not sure how to fix it, do not guess: leave it, '
                  'say which and why in one comment (or ask with `backlog ask ${item.id} "…"`), run '
                  '`backlog set ${item.id} status=${fix.then}` instead (a person looks at it there) and stop.',
      });
    } else if (repair) {
      prompt = repairFrame.render({
        ...values,
        'base': config.base,
        'context': session != null
            ? 'You continue your earlier session on this epic. Since your last run: $news\n'
                  'Run `backlog show ${item.id}` to see it as it is now.'
            : 'Since the last agent on this epic: ${replies ?? 'no new comments.'}\n'
                  'Run `backlog show ${item.id}` and `backlog epic ${item.id}$scope` first.',
        'publish': config.pr == null
            ? 'Never push and never open pull requests.'
            : 'Publish the branch with `backlog pr ${item.id} --force` (it pushes $branch and keeps the pull '
                  'request); never run `git push` and never merge.',
      });
    } else if (epic) {
      prompt = epicFrame.render({
        ...values,
        'scope': scope,
        'items': milestone == null
            ? 'all of its items'
            : 'the items of the milestone $milestone and those without a milestone (leave the others as they are)',
        'context': session != null
            ? 'You continue your earlier session on this epic. Since your last run: $news\n'
                  'Run `backlog show ${item.id}` to see it as it is now. If the new comments only ask you '
                  'something, answer with `backlog comment ${item.id} "…"` and stop; otherwise go on as below.'
            : replies != null
            ? 'Since the last agent on this epic: $replies'
            : 'First run `backlog instructions`, `backlog show ${item.id}` and `backlog epic ${item.id}$scope`.',
        'finish': config.pr == null
            ? 'run `backlog set ${item.id} status=${values['handover']}` and stop.'
            : 'write the description of one pull request for the whole epic (what changed and why, the items it '
                  'implements with their ids, how you verified it) and run '
                  '`backlog pr ${item.id} --description "<description>"`: it pushes $branch and opens the pull '
                  'request (when one exists already, it only pushes). Then run '
                  '`backlog set ${item.id} status=${values['handover']}` and stop.',
        'publish': config.pr == null
            ? 'Never push and never open pull requests.'
            : 'Never run `git push` yourself, never push other branches and never merge: `backlog pr ${item.id}` '
                  'is the only way your work leaves this worktree. If it fails, say why with '
                  '`backlog comment ${item.id} "…"` and still set the epic to ${values['handover']}.',
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
        'state': returnTo != null
            ? 'it shows as in progress while you work and goes back to $returnTo by itself when you end; change '
                  'the status only when the action asks you to'
            : 'it stays in status ${item.item.status} unless the action asks you to change it (never set it to '
                  'in-progress)',
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
      setup: create ? config.newWorktrees?.setup ?? const [] : const [],
      action: action,
      trigger: trigger,
      fix: fix,
      newSession: session == null && replies != null && action == null && fix == null,
      epic: epic,
      milestone: milestone,
      repair: repair,
      returnTo: returnTo,
    );
  }

  /// What the agent of an epic is told when people reply on it after all of
  /// its items are handed over or done ([repair]): take up the comments on
  /// {branch} without taking items — typically, after a failed merge, rebase
  /// on {base}, resolve the conflicts, check and publish (`{publish}`),
  /// leaving the statuses as they are; ask on the epic when a conflict is
  /// beyond it or not clear-cut.
  static final repairFrame = TextTemplate(
    'You are the coding agent {worktree} on the epic {id} ("{title}") in this git worktree, on its branch {branch} '
    '(commit there and do not switch branches). Every item of the epic is implemented already (handed over or '
    'done): take no items (never run `backlog epic {id} --next`) and change no status of the epic or its items. '
    'The epic is claimed for you (BACKLOG_AGENT={worktree}).\n'
    '{context}\n\n'
    'Do what the new comments ask for, on {branch}. If they only ask you something, answer with '
    '`backlog comment {id} "…"` and stop. Typically a merge of the epic failed (conflicts, checks) and its comment '
    'lists the steps; follow them. In short:\n'
    '1. Bring {branch} up to date: `git rebase {base}` (after `git fetch` when the base is remote, as the comment '
    'says).\n'
    '2. Resolve the conflicts git reports, keeping what both sides meant; `git add <file>` for each resolved file, '
    'then `git rebase --continue`; repeat until the rebase is done (never `--skip`).\n'
    '3. Run the project\'s checks (as the comment or the project\'s instructions say) and commit what they need, with '
    'the id of the item the change belongs to (else {id}) in the message.\n'
    '4. {publish}\n'
    '5. Leave every status as it is and stop; a person deploys the epic again.\n'
    'If you cannot resolve a conflict, or how to resolve it is not clear-cut (both sides changed the same thing in '
    'different ways, a decision is needed), run `git rebase --abort` so that {branch} stays as it was, ask with '
    '`backlog ask {id} "<which files conflict and what has to be decided>"` and stop; you will be resumed with the '
    'answer.\n'
    '${DispatcherConfig.talkRules}\n${DispatcherConfig.runRules}',
    known: const [...DispatcherConfig.promptPlaceholders, 'base', 'context', 'publish'],
    label: 'epic repair prompt',
  );

  /// What the agent implementing an epic is told: work through {items}
  /// with `backlog epic {id}{scope} --next` (`{scope}`: ` --milestone <m>`
  /// for a run limited to one milestone), one after another on {branch}, each
  /// handed over to review; ask on the epic and stop when the rest waits
  /// for something outside it; finish the epic (`{finish}`: review, with
  /// `dispatcher.pr` after one pull request); `{publish}`: how its work may
  /// leave the worktree.
  static final epicFrame = TextTemplate(
    'You are the coding agent {worktree}, implementing the epic {id} ("{title}") in this git worktree: {items}, '
    'one after another, in this one session and on the one branch {branch} (commit there and do not switch '
    'branches). The epic is claimed for you (BACKLOG_AGENT={worktree}); take no items outside it.\n'
    '{context}\n\n'
    '1. Run `backlog epic {id}{scope} --next`. It claims the next item of the epic for you (the one you have in '
    'progress, else the first that can start), puts it on {branch} and shows it. `backlog epic {id}{scope}` shows '
    'the whole plan.\n'
    '2. Implement that item in small commits whose messages contain its id, tick off its checklist with '
    '`backlog check <item id> <number or text>` (never edit item files), then run '
    '`backlog set <item id> status=review` and go back to step 1. Items unblocked meanwhile come up by themselves.\n'
    '3. When `backlog epic {id}{scope} --next` says nothing is left (every item handed over or done): {finish}\n'
    '4. When it says nothing can start although items are left (they wait for something outside the epic: a '
    'dependency, an answer, overlapping work), ask on the epic with `backlog ask {id} "<what blocks which items, '
    'what is done>"`, leave every status as it is and stop; you will be resumed in this session with the answer.\n'
    '5. If something about one item is unclear, ask on the epic too (`backlog ask {id} "…"`, naming the item) and '
    'stop.\n'
    '6. If a discussion changes what an item asks for, update its description or acceptance criteria in the body '
    'above the `## Discussion` section (never edit the comments).\n'
    '{publish}\n'
    '${DispatcherConfig.talkRules}\n${DispatcherConfig.runRules}',
    known: const [...DispatcherConfig.promptPlaceholders, 'scope', 'items', 'context', 'finish', 'publish'],
    label: 'epic prompt',
  );

  /// What the item's agent is told when an AI review with `auto_fix` asks
  /// for changes: fix the findings of the review (`{review}`), comment only
  /// on findings left unfixed, publish (`{publish}`), set the status it had
  /// again (which reviews it again) and stop; the talking and running rules follow.
  static final fixFrame = TextTemplate(
    'You are the agent {worktree} on backlog item {id} ("{title}") in this git worktree, on branch {branch}. The '
    'item is claimed for you (BACKLOG_AGENT={worktree}) and shows as in progress while you work (it was '
    '{status}).\n'
    '{context}\n\n'
    'An AI review of your work asks for changes (automatic fix round {round} of {rounds}). Fix its findings '
    'below in small commits whose messages contain {id}. Where a finding is wrong, do not change the code; say '
    'why in exactly one comment (`backlog comment {id} "…"`); what you fixed belongs in the commit messages, not '
    'in a comment. {publish} Then run `backlog set {id} status={status}` (that reviews it again) and stop.{decide} '
    'If something is unclear, ask with `backlog ask {id} "<your question>"` and stop.\n'
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
      'decide',
    ],
    label: 'fix prompt',
  );

  /// What the agent of a prompt action is told: who and where it is, what
  /// happens to the item's status (`{state}`: it keeps it, or it shows in
  /// progress while an action that changes code runs), the item's context, the action's text
  /// (`{task}`, for a review the built-in review task), how to finish
  /// (`{finish}`: `backlog comment`, a review `backlog review`) and how it
  /// may publish commits (`{publish}`: `backlog pr` with `dispatcher.pr`,
  /// else — and always for a review — never push).
  static final actionFrame = TextTemplate(
    'You are the agent {worktree}, started for the action "{action}" on backlog item {id} ("{title}") in this '
    'git worktree, on branch {branch}. The item is claimed for you (BACKLOG_AGENT={worktree}) only while the '
    'action runs; {state}, and you take no other items.\n'
    '{context}\n\n'
    'The action:\n{task}\n\n'
    '{finish} If something is unclear, ask with `backlog ask {id} "<your question>"` and stop. {publish}\n'
    '${DispatcherConfig.checklistRules}\n${DispatcherConfig.talkRules}\n${DispatcherConfig.runRules}',
    known: const [...ActionDefinition.promptPlaceholders, 'state', 'context', 'task', 'finish', 'publish'],
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

  /// The commands that prepare the worktree created from [createFrom]
  /// (`dispatcher.setup`, [NewWorktrees.setup]).
  final List<CommandTemplate> setup;

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

  /// The agent implements the item as an epic ([epicFrame]): it claims the
  /// item even with open children and the items under it on its branch.
  final bool epic;

  /// The milestone an [epic] run is limited to; null for all of the epic.
  final String? milestone;

  /// The epic's agent takes up replies on an epic whose items are all
  /// handed over or done ([repairFrame]; [epic] is set too): it works on the
  /// epic's branch without taking items.
  final bool repair;

  /// The status the item was handed over in (e.g. `review`) when its agent,
  /// or an action's agent that changes code, works on it again: the item
  /// shows in the active status while the agent runs and goes back here
  /// when it ends without handing the item over itself. Null: the item keeps
  /// its status.
  final String? returnTo;

  ItemId get id => item.id;

  /// The name the claim is taken under.
  String get agent => worktree.name;

  /// `<id>@<worktree>` (with `+resume` when continuing a session); equal
  /// keys mean the same decision.
  String get key =>
      '$id@${worktree.name}${resume == null ? '' : '+resume'}${newSession ? '+reply' : ''}${epic ? '+epic' : ''}${milestone == null ? '' : '@$milestone'}${repair ? '+repair' : ''}'
      '${action == null ? '' : ':${action!.name}'}'
      '${fix == null ? '' : '+fix'}';
}

/// Round [round] of [rounds] (`auto_fix`) of fixing the findings of the AI
/// [review].
final class ReviewFix {
  const ReviewFix({required this.review, required this.round, required this.rounds, this.then});

  final Comment review;
  final int round;
  final int rounds;

  /// Where the agent sends the item instead when a finding needs a person
  /// (the review's [ActionDefinition.then]); null: it always gives the item
  /// back for review.
  final String? then;
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
    this.problems = const [],
    this.queuedReplies = const {},
    this.epics = const {},
    this.epicMilestones = const {},
    this.queue = const [],
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
    // The items under an epic one agent implements are that agent's work.
    final epics = {
      for (final id in conditions.epics)
        if (snapshot[id] case final planned? when !planned.isDone) id,
    };
    final members = {
      for (final planned in snapshot.items)
        if (planned.ancestors.any(epics.contains)) planned.id,
    };
    // An item with open children that no agent implements as an epic cannot
    // start for replies: only Implement epic takes them up — unless all of
    // its items are handed over or done, then its agent repairs the branch.
    bool epicToStart(PlannedItem planned) =>
        !planned.isDone &&
        planned.openChildCount > 0 &&
        !epics.contains(planned.id) &&
        !members.contains(planned.id) &&
        !isRepair(snapshot, planned, milestone: conditions.epicMilestones[planned.id]);
    final reasons = <ItemId, String>{};
    final left = <PlannedItem>[];
    // A person wrote to an agent: first, even when held (unless its branch is
    // stuck in another worktree). Its session goes on, or without one a new
    // session takes the comments up.
    final fresh = {
      for (final planned in snapshot.items)
        if (!members.contains(planned.id) &&
            !runningItems.contains(planned.id) &&
            !conditions.blocked.contains(planned.id) &&
            hasRepliesWithoutSession(planned, sessions[planned.id], conditions.starts[planned.id], snapshot, config))
          planned.id,
    };
    final replied = [
      for (final planned in snapshot.items)
        if (fresh.contains(planned.id) ||
            (!members.contains(planned.id) &&
                !runningItems.contains(planned.id) &&
                !conditions.blocked.contains(planned.id) &&
                hasReplies(planned, sessions[planned.id], config)))
          planned,
    ];
    for (final planned in [...replied.where(epicToStart)]) {
      replied.remove(planned);
      fresh.remove(planned.id);
      left.add(planned);
      reasons[planned.id] = epicReplyReason;
    }
    final ready = [
      ...replied,
      for (final item in snapshot.ready)
        if (!conditions.held.containsKey(item.id) &&
            !replied.contains(item) &&
            !runningItems.contains(item.id) &&
            !members.contains(item.id))
          item,
    ];

    final waitingForAnswer = [
      for (final planned in snapshot.items)
        if (planned.needsHuman && !planned.isDone && sessions.containsKey(planned.id)) planned,
    ];

    final assignments = <DispatchAssignment>[];
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
          workflow: snapshot.workflow,
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
          epic: epics.contains(candidate.id),
          milestone: conditions.epicMilestones[candidate.id],
          repair:
              replied.contains(candidate) &&
              isRepair(snapshot, candidate, milestone: conditions.epicMilestones[candidate.id]),
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
          if (conditions.held[item.id] case final reason? when !replied.contains(item) && !members.contains(item.id))
            (item: item, reason: reason),
      ]),
      spare: List.unmodifiable(spare),
      recheckAt: recheckAt,
      runs: List.unmodifiable(conditions.runs),
      pending: List.unmodifiable(conditions.pending),
      branches: Map.unmodifiable(conditions.branches),
      // Held items say why already; a running item has a new run.
      problems: List.unmodifiable([
        for (final planned in snapshot.items)
          if (conditions.problems[planned.id] case final problems?
              when problems.isNotEmpty &&
                  !planned.isDone &&
                  !runningItems.contains(planned.id) &&
                  !conditions.held.containsKey(planned.id))
            (item: planned, problems: List<String>.unmodifiable(problems)),
      ]),
      queuedReplies: Map.unmodifiable({
        for (final run in conditions.runs)
          if (snapshot[run.item] case final planned?
              when !planned.isDone && planned.item.discussion.after(run.startedAt, except: run.worktree).isNotEmpty)
            run.item: run.action == null
                ? 'the agent reads it after its current run'
                : 'the agent continues after the action "${run.action}" ends',
      }),
      epics: Set.unmodifiable(epics),
      epicMilestones: Map.unmodifiable({
        for (final MapEntry(:key, :value) in conditions.epicMilestones.entries)
          if (epics.contains(key)) key: value,
      }),
      queue: List.unmodifiable(conditions.queue),
    );
  }

  /// Whether a reply on [planned] goes to its epic's agent in repair mode
  /// ([DispatchAssignment.repair]): it is unfinished, has children and a
  /// `branch` (its work was done on one branch, by an epic run), and all
  /// items under it are handed over or done ([EpicPlan.finished]; those of
  /// [milestone] when its run was limited to one), so there is nothing left
  /// to implement — only its branch to fix (e.g. a rebase after a failed
  /// merge) or questions to answer.
  static bool isRepair(BacklogSnapshot snapshot, PlannedItem planned, {String? milestone}) =>
      !planned.isDone &&
      planned.openChildCount > 0 &&
      (planned.item.branch?.trim().isNotEmpty ?? false) &&
      EpicPlan.of(snapshot, planned.id, milestone: milestone).finished;

  /// Why a reply on an item with open children that no agent implements as
  /// an epic waits ([waitingReasons]).
  static const epicReplyReason = 'it has open child items: start Implement epic to take the reply up';

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

  /// Unfinished items whose latest run ended with problems
  /// ([DispatchConditions.problems]) and that neither run nor are [held]:
  /// they need a person.
  final List<({PlannedItem item, List<String> problems})> problems;

  /// Items with something running and a person's comment written since it
  /// started (not a note or review), → when the agent takes it up: one run
  /// per item, so the reply waits for the run to end (a reply resumes the
  /// agent then, [hasReplies]).
  final Map<ItemId, String> queuedReplies;

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

  /// Unfinished epics one agent implements ([DispatchConditions.epics]).
  final Set<ItemId> epics;

  /// The milestone of each of [epics] whose run is limited to one
  /// ([DispatchConditions.epicMilestones]).
  final Map<ItemId, String> epicMilestones;

  /// Starts people asked for that wait, oldest first
  /// ([DispatchConditions.queue]).
  final List<QueuedStart> queue;

  /// The queued start of [id], if any.
  QueuedStart? queuedFor(ItemId id) => queue.firstWhereOrNull((q) => q.item == id);

  /// What [start] waits for by this plan (why it cannot start now); its
  /// last [QueuedStart.reason] when the plan sees no obstacle (the launch
  /// itself failed, e.g. a branch busy in another worktree).
  String queueReason(QueuedStart start) {
    try {
      startOf(start);
    } on BacklogException catch (error) {
      return error.message;
    }
    return start.reason ?? 'its turn';
  }

  /// What starting [start] runs now: an agent ([assignmentFor],
  /// [epicStart], a prompt action) or an action's job; fails like those.
  ({DispatchAssignment? agent, ActionJob? job}) startOf(QueuedStart start) => switch (start.kind) {
    StartKind.agent => (agent: assignmentFor(start.item.value, fresh: start.fresh), job: null),
    StartKind.epic => (agent: epicStart(start.item.value, fresh: start.fresh, milestone: start.milestone), job: null),
    StartKind.action => actionStart(start.item.value, start.action ?? '', trigger: ActionTrigger.request),
  };

  /// The epic one agent implements that [id] belongs to (lies under), if any;
  /// such items are never assigned on their own.
  ItemId? epicOf(ItemId id) => snapshot[id]?.ancestors.firstWhereOrNull(epics.contains);

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
          workflow: snapshot.workflow,
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
  DispatchAssignment fixStart(
    ItemId id, {
    required Comment review,
    required int round,
    required int rounds,
    String? then,
  }) {
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
      workflow: snapshot.workflow,
      item: planned,
      worktree: target.worktree,
      path: target.path,
      backlogRoot: backlogRoot,
      resume: own == null ? null : session,
      create: target.isNew,
      fix: ReviewFix(review: review, round: round, rounds: rounds, then: then),
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
    if (epicOf(planned.id) case final epic?) {
      throw InvalidInputException(
        '${planned.id} belongs to the epic $epic, which one agent implements on its branch; start $epic instead.',
      );
    }
    final repair = isRepair(snapshot, planned, milestone: epicMilestones[planned.id]);
    if (!planned.isDone && planned.openChildCount > 0 && !epics.contains(planned.id) && !repair) {
      throw InvalidInputException(
        '${planned.id} has ${planned.openChildCount} open child item(s): implement it as an epic '
        '(Implement epic), which also takes up the replies on it.',
      );
    }
    final replied = !fresh && hasReplies(planned, sessions[planned.id], config);
    final news = fresh ? null : _newSessionNews(planned);
    if (repair && !replied && news == null) {
      throw InvalidInputException(
        '${planned.id} has nothing left to implement: every item under it is handed over or done. '
        'Reply on it to have its agent fix its branch, or deploy it.',
      );
    }
    // An epic one agent implements goes on as an epic.
    if (epics.contains(planned.id) && !planned.isReady && !replied && news == null) {
      return epicStart(reference, fresh: fresh, milestone: epicMilestones[planned.id]);
    }
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
      workflow: snapshot.workflow,
      item: planned,
      worktree: target.worktree,
      path: target.path,
      backlogRoot: backlogRoot,
      resume: own == null ? null : session,
      create: target.isNew,
      replies: own == null ? news : null,
      epic: epics.contains(planned.id),
      milestone: epicMilestones[planned.id],
      repair: repair,
    );
  }

  /// The assignment for implementing the epic [reference] by hand, now: one
  /// agent works through all items under it on the epic's branch
  /// ([DispatchAssignment.epic]). The epic must pass [EpicPlan] (not
  /// [EpicVerdict.forbidden]; warnings are the caller's to confirm) and must
  /// not be claimed; its last session goes on in its worktree when it can,
  /// unless [fresh], else the agent starts where the epic's branch is
  /// checked out or in the first free (or new) worktree. Fails with
  /// `InvalidInputException` when it cannot start, `ClaimConflictException`
  /// when it is claimed, `UnavailableException` while something runs for it
  /// or no worktree is free. A [milestone] limits the run to the items of
  /// that milestone and those without one ([EpicPlan.milestone]); it must
  /// be one of the workflow's.
  DispatchAssignment epicStart(String reference, {bool fresh = false, String? milestone}) {
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    final id = planned.id;
    if (runFor(id) case final run?) {
      throw UnavailableException(
        '${run.action == null ? 'An agent' : 'The action "${run.action}"'} already runs for $id (in ${run.worktree}).',
      );
    }
    if (planned.isClaimed) throw ClaimConflictException('$id is claimed by ${planned.claim!.agent}.');
    if (epicOf(id) case final epic?) {
      throw InvalidInputException('$id belongs to the epic $epic, which one agent implements already.');
    }
    if (milestone != null && !snapshot.workflow.acceptsMilestone(milestone)) {
      throw InvalidInputException('Unknown milestone "$milestone".');
    }
    final plan = EpicPlan.of(snapshot, id, milestone: milestone);
    if (plan.verdict == EpicVerdict.forbidden) {
      throw InvalidInputException('$id cannot be implemented as an epic: ${plan.problems.join(' ')}');
    }
    final free = available;
    if (free.isEmpty || capacity == 0) {
      throw UnavailableException('No free worktree for the epic $id ($running/${config.maxAgents} running).');
    }
    final session = fresh ? null : sessions[id];
    final own = _resumableIn(session, config.agent, free);
    final target = own ?? free.firstWhereOrNull((w) => !w.isNew && branches[w.name] == plan.branch) ?? free.first;
    return DispatchAssignment.render(
      config,
      workflow: snapshot.workflow,
      item: planned,
      worktree: target.worktree,
      path: target.path,
      backlogRoot: backlogRoot,
      resume: own == null ? null : session,
      create: target.isNew,
      epic: true,
      milestone: plan.milestone,
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
      _sameList(other.problems.map(_problemKey), problems.map(_problemKey)) &&
      _sameList(other.queuedReplies.keys, queuedReplies.keys) &&
      _sameList(other.worktrees.map(_worktreeKey), worktrees.map(_worktreeKey)) &&
      _sameList(other.runs.map(_runKey), runs.map(_runKey)) &&
      _sameList(other.pending.map(_pendingKey), pending.map(_pendingKey)) &&
      _sameList(other.queue.map(_queueKey), queue.map(_queueKey));

  static String _queueKey(QueuedStart start) => '${start.item}:${start.kind.name}:${start.action}:${start.reason}';

  static String _runKey(AgentRun run) => '${run.item}:${run.worktree}:${run.pid}:${run.action}';

  static String _problemKey(({PlannedItem item, List<String> problems}) entry) =>
      '${entry.item.id}:${entry.problems.join('\n')}';

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

  /// The agent and action runs of [item] it has logs of, oldest first.
  Future<List<RunRecord>> runsOf(ItemId item) async => const [];

  /// Starts background work (watching processes); [onChange] is called when
  /// something the plan depends on changed outside the backlog files.
  void attach(void Function() onChange) {}

  Future<void> close() async {}
}
