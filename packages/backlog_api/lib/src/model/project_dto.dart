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
