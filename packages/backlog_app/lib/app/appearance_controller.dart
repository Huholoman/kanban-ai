import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../shared/debounced_changes.dart';
import '../shared/item_style.dart';
import '../shared/tokens.dart';

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
    _changes ??= DebouncedChanges(
      _api,
      (_) => unawaited(load()),
      delay: _refreshDelay,
      watched: const {BacklogPart.workflow},
    );
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

  /// The design tokens for [brightness], with the accent and background
  /// from `appearance` (primary, else the seed, else the built-in indigo).
  BoardTokens tokens(Brightness brightness) {
    final palette = brightness == Brightness.light ? appearance.light : appearance.dark;
    final base = brightness == Brightness.light ? BoardTokens.light : BoardTokens.dark;
    final accent = ItemStyle.parse(palette.primary) ?? ItemStyle.parse(palette.seed);
    final page = ItemStyle.parse(palette.background);
    if (accent == null && page == null) return base;
    final generated = accent == null ? null : ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
    return base.copyWith(
      accent: generated == null ? null : (palette.primary != null ? accent : generated.primary),
      accentSoft: generated?.secondaryContainer,
      onAccent: generated?.onPrimary,
      page: page,
    );
  }

  ThemeData theme(Brightness brightness) => tokens(brightness).toTheme(brightness);

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }
}
