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
  });

  factory AgentRunDto.fromJson(Json json) => AgentRunDto(
    item: json.string('item'),
    worktree: json.string('worktree'),
    pid: json.integer('pid'),
    startedAt: DateTime.parse(json.string('started_at')),
    log: json.string('log'),
    agent: json.string('agent'),
    branch: json.optionalString('branch'),
  );

  final String item;
  final String worktree;
  final int pid;
  final DateTime startedAt;

  /// Path of the log file on the server.
  final String log;

  /// Name of the agent profile.
  final String agent;
  final String? branch;

  Json toJson() => {
    'item': item,
    'worktree': worktree,
    'pid': pid,
    'started_at': startedAt.toUtc().toIso8601String(),
    'log': log,
    'agent': agent,
    'branch': branch,
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

/// A ready item proposed for (or, in auto mode, about to start in) a worktree.
final class DispatchAssignmentDto {
  const DispatchAssignmentDto({
    required this.item,
    required this.title,
    required this.worktree,
    this.newWorktree = false,
  });

  factory DispatchAssignmentDto.fromJson(Json json) => DispatchAssignmentDto(
    item: json.string('item'),
    title: json.string('title'),
    worktree: json.string('worktree'),
    newWorktree: json.boolean('new_worktree'),
  );

  final String item;
  final String title;
  final String worktree;

  /// [worktree] is created for it first.
  final bool newWorktree;

  Json toJson() => {'item': item, 'title': title, 'worktree': worktree, 'new_worktree': newWorktree};
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
    this.held = const [],
    this.maxWorktrees,
    this.spareWorktrees = 0,
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
    held: json.objects('held').map(HeldItemDto.fromJson).toList(),
    maxWorktrees: json['max_worktrees'] is int ? json['max_worktrees']! as int : null,
    spareWorktrees: json.integer('spare_worktrees'),
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
  final List<HeldItemDto> held;

  /// `dispatcher.max_worktrees` when the dispatcher adds worktrees itself
  /// (`dispatcher.repo`), else null.
  final int? maxWorktrees;

  /// How many more worktrees it may create.
  final int spareWorktrees;

  bool get isManual => mode == 'manual';

  /// An agent can start now (a worktree is free or can be created, within
  /// `max_agents`).
  bool get canStart => configured && capacity > 0 && (worktrees.any((w) => w.isFree && !w.isNew) || spareWorktrees > 0);

  /// The agent running for [item], if any.
  AgentRunDto? runFor(String item) {
    for (final worktree in worktrees) {
      if (worktree.run?.item == item) return worktree.run;
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
    'held': [for (final item in held) item.toJson()],
    'max_worktrees': maxWorktrees,
    'spare_worktrees': spareWorktrees,
  };
}

/// The end of an agent's last run.
final class AgentRunEndDto {
  const AgentRunEndDto({this.exitCode, this.reason, this.outcome, this.endedAt, this.sessionId});

  factory AgentRunEndDto.fromJson(Json json) => AgentRunEndDto(
    exitCode: json['exit_code'] is int ? json['exit_code']! as int : null,
    reason: json.optionalString('reason'),
    outcome: json.optionalString('outcome'),
    endedAt: switch (json.optionalString('ended_at')) {
      final at? => DateTime.tryParse(at),
      null => null,
    },
    sessionId: json.optionalString('session_id'),
  );

  final int? exitCode;
  final String? reason;
  final String? outcome;
  final DateTime? endedAt;

  /// Claude Code's session id: `claude --resume <id>` continues the run.
  final String? sessionId;

  Json toJson() => {
    'exit_code': exitCode,
    'reason': reason,
    'outcome': outcome,
    'ended_at': endedAt?.toUtc().toIso8601String(),
    'session_id': sessionId,
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
  const DispatchRequest(this.item);

  factory DispatchRequest.fromJson(Json json) => DispatchRequest(json.string('item'));

  /// The item (a shortened id works too).
  final String item;

  Json toJson() => {'item': item};
}
