import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

/// The live log of one item's agent: follows it over the API while
/// [start]ed — the running agent's, else the last run's — keeping at most
/// [maxLines] readable lines.
class AgentLogController extends ChangeNotifier {
  AgentLogController(this._api, this.item, {this.maxLines = 2000, this.initialLines = 200});

  final BacklogApi _api;
  final String item;
  final int maxLines;

  /// How many lines the server sends first.
  final int initialLines;

  StreamSubscription<AgentLogUpdateDto>? _subscription;
  bool _disposed = false;

  /// The lines shown, oldest first.
  List<String> lines = const [];

  /// The log file on the server; null until an agent has run for [item].
  String? path;

  /// An agent runs for [item] now.
  bool running = false;

  /// How its last run ended (when it does not run).
  AgentRunEndDto? last;

  /// The first message arrived.
  bool loaded = false;

  /// Lines dropped from the front ([maxLines]) since the last reset.
  int dropped = 0;

  /// There is a log to show.
  bool get hasLog => path != null;

  void start() {
    _subscription ??= _api.followAgentLog(item, lines: initialLines).listen(_apply, onError: (Object _) {});
  }

  void _apply(AgentLogUpdateDto update) {
    if (_disposed) return;
    final next = update.reset ? [...update.lines] : [...lines, ...update.lines];
    if (update.reset) dropped = 0;
    if (next.length > maxLines) {
      dropped += next.length - maxLines;
      next.removeRange(0, next.length - maxLines);
    }
    lines = List.unmodifiable(next);
    path = update.path;
    running = update.running;
    last = update.last;
    loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
