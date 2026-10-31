import 'package:web/web.dart' as web;

import '../features/projects/application/project_memory.dart';

/// In the browser the last project and the last view of each project are
/// kept in `localStorage` (per server origin).
ProjectMemory projectMemoryStore() => _LocalStorageMemory();

final class _LocalStorageMemory implements ProjectMemory {
  static const _key = 'kanban-ai.project';

  static String _viewKey(String? project) => project == null ? 'kanban-ai.view' : 'kanban-ai.view.$project';

  @override
  String? read() => _get(_key);

  @override
  void write(String id) => _set(_key, id);

  @override
  String? readView(String? project) => _get(_viewKey(project));

  @override
  void writeView(String? project, String view) => _set(_viewKey(project), view);

  static String? _get(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      return null; // Storage blocked (private window, site data off).
    }
  }

  static void _set(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } catch (_) {
      // Not remembered; the URL still names the project.
    }
  }
}
