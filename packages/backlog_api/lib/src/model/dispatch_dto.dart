import 'action_dto.dart';
import 'json.dart';

/// An agent process the dispatcher started that still runs.
final class AgentRunDto {
  const AgentRunDto({
    required this.item,
    required this.worktree,
    required this.pid,
    required this.startedAt,
    required this.log,
    required this.agent,
    this.branch,
    this.action,
    this.kind = 'agent',
    this.epic = false,
  });

  factory AgentRunDto.fromJson(Json json) => AgentRunDto(
    item: json.string('item'),
    worktree: json.string('worktree'),
    pid: json.integer('pid'),
    startedAt: DateTime.parse(json.string('started_at')),
    log: json.string('log'),
    agent: json.string('agent'),
    branch: json.optionalString('branch'),
    action: json.optionalString('action'),
    kind: json.optionalString('kind') ?? 'agent',
    epic: json.boolean('epic'),
  );

  final String item;
  final String worktree;
  final int pid;
  final DateTime startedAt;

  /// Path of the log file on the server.
  final String log;

  /// Name of the agent profile (the action's name for commands).
  final String agent;
  final String? branch;

  /// The action it runs for; null for the dispatcher's own agents.
  final String? action;

  /// `agent` (also for prompt actions), `command` or `builtin`.
  final String kind;

  /// The item's agent implements it as an epic: all items under it.
  final bool epic;

  Json toJson() => {
    'item': item,
    'worktree': worktree,
    'pid': pid,
    'started_at': startedAt.toUtc().toIso8601String(),
    'log': log,
    'agent': agent,
    'branch': branch,
    'action': action,
    'kind': kind,
    'epic': epic,
  };
}

/// A configured worktree of the dispatcher.
final class DispatchWorktreeDto {
  const DispatchWorktreeDto({
    required this.name,
    required this.path,
    required this.busy,
    this.claims = const [],
    this.unavailable,
    this.run,
    this.created = false,
    this.isNew = false,
  });

  factory DispatchWorktreeDto.fromJson(Json json) => DispatchWorktreeDto(
    name: json.string('name'),
    path: json.string('path'),
    busy: json.boolean('busy'),
    claims: json.strings('claims'),
    unavailable: json.optionalString('unavailable'),
    run: switch (json.optionalObject('run')) {
      final run? => AgentRunDto.fromJson(run),
      null => null,
    },
    created: json.boolean('created'),
    isNew: json.boolean('new'),
  );

  final String name;
  final String path;

  /// A live claim is held under its name or an agent runs in it.
  final bool busy;

  /// Items claimed under its name.
  final List<String> claims;

  /// Why no agent can start here now (uncommitted changes, …); null when
  /// nothing is wrong.
  final String? unavailable;

  /// The agent running here.
  final AgentRunDto? run;

  /// The dispatcher created it (`dispatcher.repo`).
  final bool created;

  /// It does not exist yet; it is created when its proposed agent starts.
  final bool isNew;

  bool get isFree => !busy && unavailable == null;

  Json toJson() => {
    'name': name,
    'path': path,
    'busy': busy,
    'free': isFree,
    'claims': claims,
    'unavailable': unavailable,
    'run': run?.toJson(),
    'created': created,
    'new': isNew,
  };
}

/// A ready item and why the dispatcher does not start it by itself.
final class HeldItemDto {
  const HeldItemDto({required this.item, required this.title, required this.reason});

  factory HeldItemDto.fromJson(Json json) =>
      HeldItemDto(item: json.string('item'), title: json.string('title'), reason: json.string('reason'));

  final String item;
  final String title;
  final String reason;

  Json toJson() => {'item': item, 'title': title, 'reason': reason};
}

/// A start a person asked for that waits until it can happen (the queue of
/// starts): [kind] `agent` (Start agent), `epic` (Implement epic) or
/// `action` ([action]); [reason] says what it waits for, [position] is its
/// place in the queue (from 1).
final class QueuedStartDto {
  const QueuedStartDto({
    required this.item,
    required this.title,
    required this.kind,
    required this.since,
    required this.reason,
    required this.position,
    this.action,
    this.fresh = false,
    this.by,
  });

  factory QueuedStartDto.fromJson(Json json) => QueuedStartDto(
    item: json.string('item'),
    title: json.string('title'),
    kind: json.string('kind'),
    since: DateTime.parse(json.string('since')),
    reason: json.string('reason'),
    position: json.integer('position', fallback: 1),
    action: json.optionalString('action'),
    fresh: json.boolean('fresh'),
    by: json.optionalString('by'),
  );

  final String item;
  final String title;
  final String kind;
  final DateTime since;
  final String reason;
  final int position;
  final String? action;
  final bool fresh;
  final String? by;

  /// `Start agent`, `Implement epic`, `"AI review"`.
  String get what => switch (kind) {
    'epic' => 'Implement epic',
    'action' => '"$action"',
    _ => fresh ? 'Start fresh' : 'Start agent',
  };

  Json toJson() => {
    'item': item,
    'title': title,
    'kind': kind,
    'since': since.toUtc().toIso8601String(),
    'reason': reason,
    'position': position,
    'action': action,
    'fresh': fresh,
    'by': by,
  };
}

/// An unfinished item whose latest run ended with problems: it needs a
/// person.
final class ProblemItemDto {
  const ProblemItemDto({required this.item, required this.title, required this.problems});

  factory ProblemItemDto.fromJson(Json json) =>
      ProblemItemDto(item: json.string('item'), title: json.string('title'), problems: json.strings('problems'));

  final String item;
  final String title;

  /// What went wrong (`the agent exited with code 1`, `2 tool calls were
  /// denied: …`, `opening its pull request failed: …`).
  final List<String> problems;

  Json toJson() => {'item': item, 'title': title, 'problems': problems};
}

/// A ready item proposed for (or, in auto mode, about to start in) a worktree.
final class DispatchAssignmentDto {
  const DispatchAssignmentDto({
    required this.item,
    required this.title,
    required this.worktree,
    this.resume,
    this.newWorktree = false,
  });

  factory DispatchAssignmentDto.fromJson(Json json) => DispatchAssignmentDto(
    item: json.string('item'),
    title: json.string('title'),
    worktree: json.string('worktree'),
    resume: json.optionalString('resume'),
    newWorktree: json.boolean('new_worktree'),
  );

  final String item;
  final String title;
  final String worktree;

  /// The session the agent continues; null for a new session.
  final String? resume;

  /// [worktree] is created for it first.
  final bool newWorktree;

  Json toJson() => {'item': item, 'title': title, 'worktree': worktree, 'resume': resume, 'new_worktree': newWorktree};
}

/// The session of an item's last agent run that a new start continues.
final class AgentSessionDto {
  const AgentSessionDto({required this.item, required this.session, required this.worktree, this.endedAt, this.reason});

  factory AgentSessionDto.fromJson(Json json) => AgentSessionDto(
    item: json.string('item'),
    session: json.string('session_id'),
    worktree: json.string('worktree'),
    endedAt: switch (json.optionalString('ended_at')) {
      final at? => DateTime.tryParse(at),
      null => null,
    },
    reason: json.optionalString('reason'),
  );

  final String item;

  /// The agent's session id.
  final String session;

  /// Where it ran; it can only be continued there.
  final String worktree;
  final DateTime? endedAt;

  /// How the run ended.
  final String? reason;

  Json toJson() => {
    'item': item,
    'session_id': session,
    'worktree': worktree,
    'ended_at': endedAt?.toUtc().toIso8601String(),
    'reason': reason,
  };
}

/// The dispatcher's current plan (`GET /api/dispatch`).
final class DispatchDto {
  const DispatchDto({
    required this.configured,
    this.mode,
    this.agent,
    this.maxAgents = 0,
    this.running = 0,
    this.capacity = 0,
    this.worktrees = const [],
    this.assignments = const [],
    this.waiting = const [],
    this.waitingReasons = const [],
    this.held = const [],
    this.sessions = const [],
    this.maxWorktrees,
    this.spareWorktrees = 0,
    this.runs = const [],
    this.pendingActions = const [],
    this.problems = const [],
    this.queuedReplies = const [],
    this.epics = const [],
    this.queue = const [],
  });

  /// No `dispatcher` section in `backlog.yaml`.
  static const off = DispatchDto(configured: false);

  factory DispatchDto.fromJson(Json json) => DispatchDto(
    configured: json.boolean('configured'),
    mode: json.optionalString('mode'),
    agent: json.optionalString('agent'),
    maxAgents: json.integer('max_agents'),
    running: json.integer('running'),
    capacity: json.integer('capacity'),
    worktrees: json.objects('worktrees').map(DispatchWorktreeDto.fromJson).toList(),
    assignments: json.objects('assignments').map(DispatchAssignmentDto.fromJson).toList(),
    waiting: json.strings('waiting'),
    waitingReasons: json.objects('waiting_reasons').map(HeldItemDto.fromJson).toList(),
    held: json.objects('held').map(HeldItemDto.fromJson).toList(),
    sessions: json.objects('sessions').map(AgentSessionDto.fromJson).toList(),
    maxWorktrees: json['max_worktrees'] is int ? json['max_worktrees']! as int : null,
    spareWorktrees: json.integer('spare_worktrees'),
    runs: json.objects('runs').map(AgentRunDto.fromJson).toList(),
    pendingActions: json.objects('pending_actions').map(PendingActionDto.fromJson).toList(),
    problems: json.objects('problems').map(ProblemItemDto.fromJson).toList(),
    queuedReplies: json.objects('queued_replies').map(HeldItemDto.fromJson).toList(),
    epics: json.strings('epics'),
    queue: json.objects('queue').map(QueuedStartDto.fromJson).toList(),
  );

  final bool configured;

  /// `auto` or `manual`.
  final String? mode;

  /// Name of the agent profile.
  final String? agent;
  final int maxAgents;
  final int running;

  /// How many more agents may start.
  final int capacity;
  final List<DispatchWorktreeDto> worktrees;
  final List<DispatchAssignmentDto> assignments;

  /// Ready items left over (ids, most urgent first).
  final List<String> waiting;

  /// Why each of [waiting] cannot start now (`no free worktree`, …), in the
  /// same order.
  final List<HeldItemDto> waitingReasons;
  final List<HeldItemDto> held;

  /// Unfinished items whose last agent session the configured agent can
  /// continue.
  final List<AgentSessionDto> sessions;

  /// `dispatcher.max_worktrees` when the dispatcher adds worktrees itself
  /// (`dispatcher.repo`), else null.
  final int? maxWorktrees;

  /// How many more worktrees it may create.
  final int spareWorktrees;

  /// Everything running: agents (also of prompt actions) and the commands
  /// and built-ins of actions, inside the worktrees or not.
  final List<AgentRunDto> runs;

  /// `on_enter` actions waiting to run.
  final List<PendingActionDto> pendingActions;

  /// Unfinished items whose latest run ended with problems, which neither
  /// run nor are [held].
  final List<ProblemItemDto> problems;

  /// Items where something runs and a person's comment written since waits
  /// for the run to end; the reason says when the agent takes it up.
  final List<HeldItemDto> queuedReplies;

  /// When the agent takes up the comment that waits on [item]; null when
  /// none waits.
  String? queuedReplyOf(String item) {
    for (final queued in queuedReplies) {
      if (queued.item == item) return queued.reason;
    }
    return null;
  }

  /// What went wrong in the latest run of [item]; empty when nothing did.
  List<String> problemsOf(String item) {
    for (final entry in problems) {
      if (entry.item == item) return entry.problems;
    }
    return const [];
  }

  /// Unfinished epics one agent implements (running or last run), ids.
  final List<String> epics;

  /// Starts people asked for that wait until they can happen, in order.
  final List<QueuedStartDto> queue;

  /// The queued start of [item]; null when none waits.
  QueuedStartDto? queuedFor(String item) {
    for (final queued in queue) {
      if (queued.item == item) return queued;
    }
    return null;
  }

  /// The `on_enter` actions waiting to run for [item].
  List<PendingActionDto> pendingFor(String item) => [
    for (final pending in pendingActions)
      if (pending.item == item) pending,
  ];

  bool get isManual => mode == 'manual';

  /// An agent can start now (a worktree is free or can be created, within
  /// `max_agents`).
  bool get canStart => configured && capacity > 0 && (worktrees.any((w) => w.isFree && !w.isNew) || spareWorktrees > 0);

  /// The agent running for [item], if any.
  AgentRunDto? runFor(String item) {
    for (final run in runs) {
      if (run.item == item) return run;
    }
    for (final worktree in worktrees) {
      if (worktree.run?.item == item) return worktree.run;
    }
    return null;
  }

  /// The agent of another item that works on [item]: nothing runs for
  /// [item] itself, but an agent runs in the worktree [claimedBy] that holds
  /// its claim — e.g. the agent of an epic going through its children.
  AgentRunDto? runWorkingOn(String item, String? claimedBy) {
    if (claimedBy == null || runFor(item) != null) return null;
    for (final run in [...runs, for (final worktree in worktrees) ?worktree.run]) {
      if (run.worktree == claimedBy && run.item != item && run.kind == 'agent') return run;
    }
    return null;
  }

  /// Why [item] is held, or null.
  String? heldReason(String item) {
    for (final held in this.held) {
      if (held.item == item) return held.reason;
    }
    return null;
  }

  /// Why [item] waits for an agent that cannot start yet, or null.
  String? waitingReason(String item) {
    for (final waiting in waitingReasons) {
      if (waiting.item == item) return waiting.reason;
    }
    return null;
  }

  /// The session a start of [item] continues, if any.
  AgentSessionDto? sessionFor(String item) {
    for (final session in sessions) {
      if (session.item == item) return session;
    }
    return null;
  }

  Json toJson() => {
    'configured': configured,
    'mode': mode,
    'agent': agent,
    'max_agents': maxAgents,
    'running': running,
    'capacity': capacity,
    'worktrees': [for (final worktree in worktrees) worktree.toJson()],
    'assignments': [for (final assignment in assignments) assignment.toJson()],
    'waiting': waiting,
    'waiting_reasons': [for (final item in waitingReasons) item.toJson()],
    'held': [for (final item in held) item.toJson()],
    'sessions': [for (final session in sessions) session.toJson()],
    'max_worktrees': maxWorktrees,
    'spare_worktrees': spareWorktrees,
    'runs': [for (final run in runs) run.toJson()],
    'pending_actions': [for (final pending in pendingActions) pending.toJson()],
    'problems': [for (final problem in problems) problem.toJson()],
    'queued_replies': [for (final queued in queuedReplies) queued.toJson()],
    'epics': epics,
    'queue': [for (final queued in queue) queued.toJson()],
  };
}

/// The end of an agent's last run.
final class AgentRunEndDto {
  const AgentRunEndDto({
    this.exitCode,
    this.reason,
    this.outcome,
    this.endedAt,
    this.sessionId,
    this.result,
    this.problems = const [],
  });

  factory AgentRunEndDto.fromJson(Json json) => AgentRunEndDto(
    exitCode: json['exit_code'] is int ? json['exit_code']! as int : null,
    reason: json.optionalString('reason'),
    outcome: json.optionalString('outcome'),
    endedAt: switch (json.optionalString('ended_at')) {
      final at? => DateTime.tryParse(at),
      null => null,
    },
    sessionId: json.optionalString('session_id'),
    result: json.optionalString('result'),
    problems: json.strings('problems'),
  );

  final int? exitCode;
  final String? reason;
  final String? outcome;
  final DateTime? endedAt;

  /// Claude Code's session id: `claude --resume <id>` continues the run.
  final String? sessionId;

  /// The agent's final message (Claude's `result`); null for other agents
  /// and commands.
  final String? result;

  /// What went wrong; empty when the run went well.
  final List<String> problems;

  Json toJson() => {
    'exit_code': exitCode,
    'reason': reason,
    'outcome': outcome,
    'ended_at': endedAt?.toUtc().toIso8601String(),
    'session_id': sessionId,
    'result': result,
    'problems': problems,
  };
}

/// The tail of an agent's log (`GET /api/dispatch/log/<item>`): of the
/// running agent, else of the last run.
final class AgentLogDto {
  const AgentLogDto({required this.item, required this.path, required this.running, this.lines = const [], this.last});

  factory AgentLogDto.fromJson(Json json) => AgentLogDto(
    item: json.string('item'),
    path: json.string('path'),
    running: json.boolean('running'),
    lines: json.strings('lines'),
    last: switch (json.optionalObject('last')) {
      final last? => AgentRunEndDto.fromJson(last),
      null => null,
    },
  );

  final String item;
  final String path;
  final bool running;
  final List<String> lines;

  /// How the last run ended; null while running.
  final AgentRunEndDto? last;

  Json toJson() => {'item': item, 'path': path, 'running': running, 'lines': lines, 'last': last?.toJson()};
}

/// `POST /api/dispatch/start` and `/stop`.
final class DispatchRequest {
  const DispatchRequest(this.item, {this.fresh = false});

  factory DispatchRequest.fromJson(Json json) => DispatchRequest(json.string('item'), fresh: json.boolean('fresh'));

  /// The item (a shortened id works too).
  final String item;

  /// Start: a new agent session even when the last one could be continued.
  final bool fresh;

  Json toJson() => {'item': item, if (fresh) 'fresh': fresh};
}
