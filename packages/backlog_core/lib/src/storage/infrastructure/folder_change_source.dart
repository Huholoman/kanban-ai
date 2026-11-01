import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../../infrastructure/backlog_layout.dart';
import '../domain/change_source.dart';

/// Watches a backlog folder and reports changes in batches.
///
/// Edits come from agents, from git and from editors, often as bursts of
/// several file events (temp file, rename, lock); they are collected for
/// [debounce] and reported as one [StorageChange].
final class FolderChangeSource implements ChangeSource {
  FolderChangeSource(this.root, {this.debounce = const Duration(milliseconds: 150), Watcher? watcher})
    : _watcher = watcher ?? DirectoryWatcher(root);

  final String root;
  final Duration debounce;
  final Watcher _watcher;
  final _changes = StreamController<StorageChange>.broadcast();
  final _pending = <String>{};
  StreamSubscription<WatchEvent>? _subscription;
  Timer? _timer;

  @override
  Stream<StorageChange> get changes => _changes.stream;

  @override
  Future<void> start() async {
    _subscription ??= _watcher.events.listen(_onEvent);
    await _watcher.ready;
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    await _subscription?.cancel();
    await _changes.close();
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
    if (_pending.isEmpty || _changes.isClosed) return;
    final paths = _pending.toList()..sort();
    _pending.clear();
    _changes.add(StorageChange(paths, configuration: paths.contains(BacklogLayout.configFileName)));
  }
}
