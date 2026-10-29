import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

/// Watches a backlog folder and reports changes in batches.
///
/// Edits come from agents, from git and from editors, often as bursts of
/// several file events (temp file, rename, lock); they are collected for
/// [debounce] and reported as one [BacklogChangeEvent].
final class ChangeFeed {
  ChangeFeed(this.root, {this.debounce = const Duration(milliseconds: 150), Watcher? watcher})
    : _watcher = watcher ?? DirectoryWatcher(root);

  final String root;
  final Duration debounce;
  final Watcher _watcher;
  final _events = StreamController<BacklogChangeEvent>.broadcast();
  final _pending = <String>{};
  StreamSubscription<WatchEvent>? _subscription;
  Timer? _timer;

  Stream<BacklogChangeEvent> get events => _events.stream;

  /// Completes once the watcher is ready, so that later changes are seen.
  Future<void> start() async {
    _subscription ??= _watcher.events.listen(_onEvent);
    await _watcher.ready;
  }

  Future<void> close() async {
    _timer?.cancel();
    await _subscription?.cancel();
    await _events.close();
  }

  /// Whether a change of [relativePath] matters to clients.
  static bool isRelevant(String relativePath) {
    final parts = p.split(relativePath);
    if (parts.any((part) => part == '.git')) return false;
    final name = parts.last;
    return !name.endsWith('.tmp') && !name.endsWith('.stale') && !name.endsWith('~') && !name.startsWith('.#');
  }

  void _onEvent(WatchEvent event) {
    final relative = p.relative(event.path, from: root);
    if (!isRelevant(relative)) return;
    _pending.add(p.posix.joinAll(p.split(relative)));
    _timer ??= Timer(debounce, _flush);
  }

  void _flush() {
    _timer = null;
    if (_pending.isEmpty || _events.isClosed) return;
    final paths = _pending.toList()..sort();
    _pending.clear();
    _events.add(BacklogChangeEvent(paths));
  }
}
