import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../features/item/application/drafts.dart';

/// Drafts in the platform's preferences (`shared_preferences`: `localStorage`
/// in the browser, per server origin; a file or the system's store on Linux,
/// Android and the rest), so they outlast a reload and a closed app. Falls
/// back to memory when the preferences cannot be opened.
Future<DraftStore> draftStore() async {
  try {
    final preferences = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    return _PreferencesDrafts(preferences);
  } catch (_) {
    return InMemoryDraftStore(); // Storage blocked (private window, site data off).
  }
}

final class _PreferencesDrafts implements DraftStore {
  _PreferencesDrafts(this._preferences);

  final SharedPreferencesWithCache _preferences;

  static String _key(String key) => 'kanban-ai.draft.$key';

  @override
  String? read(String key) => _preferences.getString(_key(key));

  @override
  void write(String key, String text) {
    // The cache changes at once; a failed write only loses the draft.
    final saved = text.trim().isEmpty ? _preferences.remove(_key(key)) : _preferences.setString(_key(key), text);
    unawaited(saved.catchError((Object _) {}));
  }
}
