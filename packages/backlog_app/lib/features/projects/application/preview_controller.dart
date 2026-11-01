import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

/// The local preview the server runs (the built-in action `preview`, a
/// button such as "Deploy locally"), shared by the board and the dashboard:
/// asked for at [start] and every [every] after (a preview restarts the
/// server, so no change event announces it), and "Back to main".
class PreviewController extends ChangeNotifier {
  PreviewController(this._api, {this.every = const Duration(seconds: 15)});

  /// Null for a single backlog without projects: there is no preview then.
  final ProjectsApi? _api;
  final Duration every;
  Timer? _timer;
  bool _disposed = false;

  /// The preview running now; null when the server runs its main build (or
  /// does not know previews).
  PreviewDto? current;

  /// "Back to main" was asked for and the server restarts.
  bool restarting = false;

  /// Why "Back to main" failed.
  String? error;

  Future<void> start() async {
    if (_api == null) return;
    await refresh();
    _timer ??= Timer.periodic(every, (_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null || restarting) return;
    PreviewDto? preview;
    try {
      preview = await api.preview();
    } catch (_) {
      return; // restarting, unreachable, or an older server: keep what we know
    }
    if (_disposed) return;
    current = preview;
    notifyListeners();
  }

  /// Ends the preview: the server restarts as its main build. Returns the
  /// program it restarts as; null when it failed ([error]).
  Future<String?> backToMain() async {
    final api = _api;
    if (api == null) return null;
    restarting = true;
    error = null;
    notifyListeners();
    try {
      final ended = await api.backToMain();
      current = null;
      return ended.mainServer;
    } on BacklogApiException catch (e) {
      error = e.message;
      return null;
    } catch (e) {
      error = '$e';
      return null;
    } finally {
      restarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
