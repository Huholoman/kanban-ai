import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../shared/debounced_changes.dart';
import '../shared/item_style.dart';

/// Theme of the app from `appearance` in backlog.yaml, reloaded when the file
/// changes, plus the mode the user switched to in this session.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._api, {Duration refreshDelay = const Duration(milliseconds: 300)})
    : _refreshDelay = refreshDelay;

  final BacklogApi _api;
  final Duration _refreshDelay;
  DebouncedChanges? _changes;

  AppearanceDto appearance = const AppearanceDto();

  /// Chosen in the app; null follows backlog.yaml.
  ThemeMode? _override;

  ThemeMode get mode =>
      _override ??
      switch (appearance.mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Future<void> start() async {
    _changes ??= DebouncedChanges(_api, () => unawaited(load()), delay: _refreshDelay);
    await load();
  }

  Future<void> load() async {
    try {
      appearance = (await _api.workflow()).appearance;
      notifyListeners();
    } catch (_) {
      // Keep the current look; the board reports connection problems.
    }
  }

  /// system → light → dark → system.
  void cycleMode() {
    _override = switch (mode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    notifyListeners();
  }

  ThemeData theme(Brightness brightness) {
    final palette = brightness == Brightness.light ? appearance.light : appearance.dark;
    var scheme = ColorScheme.fromSeed(
      seedColor: ItemStyle.parse(palette.seed) ?? const Color(0xFF3A6EA5),
      brightness: brightness,
    );
    scheme = scheme.copyWith(
      primary: ItemStyle.parse(palette.primary),
      secondary: ItemStyle.parse(palette.secondary),
      surface: ItemStyle.parse(palette.background),
    );
    return ThemeData(colorScheme: scheme, visualDensity: VisualDensity.standard);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }
}
