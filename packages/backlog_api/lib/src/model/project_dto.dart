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
