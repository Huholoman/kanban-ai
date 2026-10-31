import 'dart:async';
import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';

import '../backlog_host.dart';
import 'hosted_project.dart';

/// The projects a server hosts, in registry order, and the routing of `/api/`
/// to them: `/api/p/<id>/…` to project `<id>`, the other paths (except the
/// global [ApiPaths.health] and [ApiPaths.projects]) to the default project,
/// the first one.
final class ProjectHub {
  /// [create] builds the project for a new registry entry; [registry] edits
  /// the registry file (pinning), null when the server hosts a fixed backlog.
  ProjectHub(this._create, {ProjectService? registry}) : _registry = registry;

  /// One project fed by [events], for tests without sockets.
  factory ProjectHub.single(
    BacklogHost host, {
    Stream<BacklogChangeEvent> events = const Stream.empty(),
    Dispatcher? dispatcher,
    AgentLauncher? launcher,
  }) {
    final entry = ProjectEntry.at(host.root);
    return ProjectHub((_) => throw StateError('fixed hub'))
      .._projects.add(HostedProject.fixed(entry, host, events: events, dispatcher: dispatcher, launcher: launcher));
  }

  final HostedProject Function(ProjectEntry entry) _create;
  final ProjectService? _registry;
  final _projects = <HostedProject>[];
  Future<void> _queue = Future.value();
  bool _closed = false;

  List<HostedProject> get projects => List.unmodifiable(_projects);

  /// The project answering the unprefixed paths.
  HostedProject? get defaultProject => _projects.isEmpty ? null : _projects.first;

  HostedProject? operator [](String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  /// Makes the hosted projects match [registry]: new entries start, removed
  /// ones stop, a changed path restarts, a changed name or order applies in
  /// place. Calls run one after another.
  Future<void> sync(ProjectRegistry registry) {
    final result = _queue.then((_) => _sync(registry));
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _sync(ProjectRegistry registry) async {
    if (_closed) return;
    final current = {for (final project in _projects) project.id: project};
    final next = <HostedProject>[];
    for (final entry in registry.entries) {
      final existing = current[entry.id];
      if (existing != null && existing.host.root == BacklogHost(entry.path).root) {
        existing.entry = entry;
        current.remove(entry.id);
        next.add(existing);
      } else {
        next.add(_create(entry));
      }
    }
    for (final stale in current.values) {
      await stale.close();
    }
    _projects
      ..clear()
      ..addAll(next);
    for (final project in next) {
      await project.ensureStarted();
    }
  }

  Future<void> close() async {
    _closed = true;
    await _queue;
    for (final project in _projects) {
      await project.close();
    }
    _projects.clear();
  }

  /// Answers every `/api/…` request.
  Handler get handler => (request) async {
    final segments = request.url.path.split('/');
    if (request.url.path == ApiPaths.health.substring(1)) return _json({'ok': true});
    if (request.url.path == ApiPaths.projects.substring(1)) {
      if (request.method != 'GET') return _notFound('No such endpoint.');
      return _json([for (final project in projects) (await project.describe()).toJson()]);
    }
    if (segments.length == 3 && segments[1] == 'projects' && request.method == 'PATCH') {
      return _patchProject(Uri.decodeComponent(segments[2]), await request.readAsString());
    }
    if (segments.length >= 3 && segments[1] == 'p') {
      final id = Uri.decodeComponent(segments[2]);
      final project = this[id];
      if (project == null) return _notFound('No project "$id"; see ${ApiPaths.projects}.');
      return project.handler(request.change(path: 'api/p/${segments[2]}'));
    }
    final fallback = defaultProject;
    if (fallback == null) return _notFound('No projects registered; add one with `backlog projects add`.');
    return fallback.handler(request.change(path: 'api'));
  };

  /// `PATCH /api/projects/<id>` `{pinned}`: writes `pinned` into the
  /// registry file and applies it at once (the registry watcher would too).
  Future<Response> _patchProject(String id, String body) async {
    final registry = _registry;
    if (registry == null) {
      return _invalid('This server hosts one backlog without a project registry; nothing to pin.');
    }
    final Object? payload;
    try {
      payload = body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException catch (error) {
      return _invalid('Request body is not JSON: ${error.message}');
    }
    if (payload is! Map || payload['pinned'] is! bool) return _invalid('Give {"pinned": true|false}.');
    try {
      await registry.setPinned(id, payload['pinned'] as bool);
      await sync(await registry.registry());
    } on NotFoundException catch (error) {
      return _notFound(error.message);
    } on BacklogException catch (error) {
      return _invalid(error.message);
    }
    final project = this[id];
    if (project == null) return _notFound('No project "$id"; see ${ApiPaths.projects}.');
    return _json((await project.describe()).toJson());
  }

  static Response _invalid(String message) =>
      _json(BacklogApiException(400, 'invalid_input', message).toJson(), status: 400);

  static Response _notFound(String message) =>
      _json(BacklogApiException(404, 'not_found', message).toJson(), status: 404);

  static Response _json(Object? body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
  );
}
