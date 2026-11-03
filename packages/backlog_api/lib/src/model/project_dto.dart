import 'json.dart';

/// A backlog served by the server, from the project registry.
final class ProjectDto {
  const ProjectDto({required this.id, required this.name, required this.path, this.error, this.pinned = false});

  factory ProjectDto.fromJson(Json json) => ProjectDto(
    id: json.string('id'),
    name: json.string('name'),
    path: json.string('path'),
    error: json.optionalString('error'),
    pinned: json.boolean('pinned'),
  );

  /// Stable slug used in URLs (`/api/p/<id>/…`).
  final String id;

  /// Display name.
  final String name;

  /// Absolute path of the backlog folder on the server.
  final String path;

  /// Why the backlog cannot be opened (missing folder, broken `backlog.yaml`);
  /// null when it works.
  final String? error;

  /// `pinned: true` in the registry: offered first in the project switcher.
  final bool pinned;

  bool get isAvailable => error == null;

  Json toJson() => {'id': id, 'name': name, 'path': path, 'error': error, 'pinned': pinned};
}

/// The local preview the server runs (`GET /api/preview`): the board runs
/// from [branch] of item [item] in project [project], rebased onto [base]
/// at [commit], since [since]. "Back to main" (`POST /api/preview/main`)
/// restarts the server as [mainServer].
final class PreviewDto {
  const PreviewDto({
    required this.project,
    required this.item,
    required this.title,
    required this.branch,
    required this.commit,
    required this.base,
    required this.since,
    required this.server,
    required this.mainServer,
  });

  factory PreviewDto.fromJson(Json json) => PreviewDto(
    project: json.string('project'),
    item: json.string('item'),
    title: json.optionalString('title') ?? '',
    branch: json.string('branch'),
    commit: json.string('commit'),
    base: json.optionalString('base') ?? 'main',
    since: DateTime.parse(json.string('since')),
    server: json.optionalString('server') ?? '',
    mainServer: json.optionalString('main_server') ?? '',
  );

  final String project;
  final String item;
  final String title;
  final String branch;
  final String commit;
  final String base;
  final DateTime since;

  /// The server program the preview runs as.
  final String server;

  /// The server program "Back to main" restarts with.
  final String mainServer;

  /// [commit] shortened for display.
  String get shortCommit => commit.length > 7 ? commit.substring(0, 7) : commit;

  Json toJson() => {
    'project': project,
    'item': item,
    'title': title,
    'branch': branch,
    'commit': commit,
    'base': base,
    'since': since.toUtc().toIso8601String(),
    'server': server,
    'main_server': mainServer,
  };
}

/// The global commands of the server (`GET /api/commands`, `commands` in
/// `server.yaml`) and the [run] of the one running or run last.
final class CommandsDto {
  const CommandsDto({this.commands = const [], this.run});

  factory CommandsDto.fromJson(Json json) => CommandsDto(
    commands: json.objects('commands').map(ServerCommandDto.fromJson).toList(),
    run: switch (json.optionalObject('run')) {
      final Json run => CommandRunDto.fromJson(run),
      null => null,
    },
  );

  final List<ServerCommandDto> commands;
  final CommandRunDto? run;

  Json toJson() => {
    'commands': [for (final command in commands) command.toJson()],
    'run': run?.toJson(),
  };
}

/// A global command of the server, started with `POST /api/commands/<name>`;
/// [restarts] when the server restarts after it succeeded.
final class ServerCommandDto {
  const ServerCommandDto({required this.name, this.restarts = false});

  factory ServerCommandDto.fromJson(Json json) =>
      ServerCommandDto(name: json.string('name'), restarts: json.boolean('restarts'));

  final String name;
  final bool restarts;

  Json toJson() => {'name': name, 'restarts': restarts};
}

/// A run of a global command: running until [finished], then [succeeded]
/// or failed (exit code, or [error]); [output] is its end. [restart] is the
/// program the server restarts as after it succeeded.
final class CommandRunDto {
  const CommandRunDto({
    required this.name,
    required this.started,
    this.finished,
    this.exitCode,
    this.output = '',
    this.error,
    this.restart,
  });

  factory CommandRunDto.fromJson(Json json) => CommandRunDto(
    name: json.string('name'),
    started: DateTime.parse(json.string('started')),
    finished: switch (json.optionalString('finished')) {
      final String time => DateTime.parse(time),
      null => null,
    },
    exitCode: json['exit_code'] as int?,
    output: json.optionalString('output') ?? '',
    error: json.optionalString('error'),
    restart: json.optionalString('restart'),
  );

  final String name;
  final DateTime started;
  final DateTime? finished;
  final int? exitCode;
  final String output;
  final String? error;
  final String? restart;

  bool get running => finished == null;

  bool get succeeded => finished != null && exitCode == 0 && error == null;

  Json toJson() => {
    'name': name,
    'started': started.toUtc().toIso8601String(),
    'finished': finished?.toUtc().toIso8601String(),
    'exit_code': exitCode,
    'output': output,
    'error': error,
    'restart': restart,
  };
}
