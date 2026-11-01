import 'package:web/web.dart' as web;

import '../features/item/application/drafts.dart';

/// In the browser drafts are kept in `localStorage` (per server origin), so
/// they outlast a reload and a closed tab.
DraftStore draftStore() => _LocalStorageDrafts();

final class _LocalStorageDrafts implements DraftStore {
  static String _key(String key) => 'kanban-ai.draft.$key';

  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(_key(key));
    } catch (_) {
      return null; // Storage blocked (private window, site data off).
    }
  }

  @override
  void write(String key, String text) {
    try {
      if (text.trim().isEmpty) {
        web.window.localStorage.removeItem(_key(key));
      } else {
        web.window.localStorage.setItem(_key(key), text);
      }
    } catch (_) {
      // Not kept; the text stays in the field while it is open.
    }
  }
}
