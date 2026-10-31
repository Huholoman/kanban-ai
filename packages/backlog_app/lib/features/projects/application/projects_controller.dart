import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import 'project_memory.dart';

/// Which backlog the app shows: the server's projects, the open one and the
/// [BacklogApi] of it. Opening another project hands out a new [api]; the
/// app throws away everything built on the old one.
///
/// The first project opened is the one [requested] in the URL, else the one
/// this viewer used last, else the first available one. A server without
/// projects (`/api/projects` answers 404) or an app given no [ProjectsApi]
/// shows the single backlog of [fallback].
class ProjectsController extends ChangeNotifier {
  ProjectsController(this._projectsApi, {BacklogApi? fallback, ProjectMemory? memory, this.requested})
    : assert(_projectsApi != null || fallback != null, 'Needs projects or a single backlog.'),
      _fallback = fallback,
      _memory = memory ?? InMemoryProjectMemory();

  final ProjectsApi? _projectsApi;
  final BacklogApi? _fallback;
  final ProjectMemory _memory;

  /// Project id from the URL the page was opened with.
  final String? requested;

  /// Registered projects in the registry's order, available or not; empty
  /// for a single backlog.
  List<ProjectDto> projects = const [];

  /// The open project; null for a single backlog or while nothing is open.
  ProjectDto? current;

  /// API of the open backlog; null while loading or when none can be opened.
  BacklogApi? api;

  bool loading = true;

  /// Why the projects could not be loaded.
  Object? error;

  /// The server has no projects: one backlog on the unprefixed paths.
  bool get single => api != null && current == null;

  /// Projects that can be opened.
  Iterable<ProjectDto> get available => projects.where((project) => project.isAvailable);

  /// Projects pinned in the registry, offered first by the switcher.
  List<ProjectDto> get pinned => [
    for (final project in projects)
      if (project.pinned) project,
  ];

  /// Pins project [id] in the server's registry (shared by every viewer) or
  /// unpins it. Throws when the server refuses.
  Future<void> setPinned(String id, bool pinned) async {
    final updated = await _projectsApi!.setPinned(id, pinned);
    projects = [for (final project in projects) project.id == id ? updated : project];
    if (current?.id == id) current = updated;
    notifyListeners();
  }

  Future<void> start() async {
    final projectsApi = _projectsApi;
    if (projectsApi == null) return _openSingle();
    loading = true;
    error = null;
    notifyListeners();
    final List<ProjectDto> loaded;
    try {
      loaded = await projectsApi.projects();
    } on BacklogApiException catch (e) {
      if (e.statusCode == 404 && _fallback != null) return _openSingle();
      return _fail(e);
    } catch (e) {
      return _fail(e);
    }
    projects = loaded;
    loading = false;
    final chosen =
        _selectable(current?.id) ?? _selectable(requested) ?? _selectable(_memory.read()) ?? available.firstOrNull;
    if (chosen == null) {
      current = null;
      api = null;
      notifyListeners();
      return;
    }
    _open(chosen);
  }

  /// Opens project [id]; unknown and unavailable projects are ignored.
  void select(String id) {
    if (id == current?.id) return;
    if (_selectable(id) case final project?) _open(project);
  }

  /// The view last chosen in the open project (or the single backlog).
  String? get lastView => _memory.readView(current?.id);

  /// Remembers [view] as the one to show when the open project is opened
  /// again.
  void rememberView(String view) => _memory.writeView(current?.id, view);

  ProjectDto? _selectable(String? id) => id == null ? null : available.where((p) => p.id == id).firstOrNull;

  void _open(ProjectDto project) {
    current = project;
    api = _projectsApi!.project(project.id);
    _memory.write(project.id);
    notifyListeners();
  }

  void _openSingle() {
    projects = const [];
    current = null;
    api = _fallback;
    loading = false;
    error = null;
    notifyListeners();
  }

  void _fail(Object e) {
    error = e;
    loading = false;
    notifyListeners();
  }
}
