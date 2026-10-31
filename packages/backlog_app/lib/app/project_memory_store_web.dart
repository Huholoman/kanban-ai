import 'package:web/web.dart' as web;

import '../features/projects/application/project_memory.dart';

/// In the browser the last project is kept in `localStorage` (per server
/// origin).
ProjectMemory projectMemoryStore() => _LocalStorageMemory();

final class _LocalStorageMemory implements ProjectMemory {
  static const _key = 'kanban-ai.project';

  @override
  String? read() {
    try {
      return web.window.localStorage.getItem(_key);
    } catch (_) {
      return null; // Storage blocked (private window, site data off).
    }
  }

  @override
  void write(String id) {
    try {
      web.window.localStorage.setItem(_key, id);
    } catch (_) {
      // Not remembered; the URL still names the project.
    }
  }
}
