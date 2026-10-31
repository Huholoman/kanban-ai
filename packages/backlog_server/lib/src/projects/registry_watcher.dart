import 'dart:async';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

/// Re-reads the project registry file whenever it changes (also when an
/// editor or `backlog projects` replaces it by a rename) and reports the new
/// registry; a malformed file is reported through `onError` and ignored.
final class RegistryWatcher {
  RegistryWatcher(
    this.store, {
    this.debounce = const Duration(milliseconds: 150),
    required this.onChange,
    required this.onError,
    Watcher? watcher,
  }) : _watcher = watcher ?? DirectoryWatcher(p.dirname(store.file));

  final YamlProjectRegistryStore store;
  final Duration debounce;
  final FutureOr<void> Function(ProjectRegistry registry) onChange;
  final void Function(Object error) onError;
  final Watcher _watcher;
  StreamSubscription<WatchEvent>? _subscription;
  Timer? _timer;

  /// Completes once changes are being watched.
  Future<void> start() async {
    _subscription ??= _watcher.events.listen((event) {
      if (!p.equals(event.path, store.file)) return;
      _timer?.cancel();
      _timer = Timer(debounce, _reload);
    });
    await _watcher.ready;
  }

  Future<void> _reload() async {
    try {
      await onChange(await store.load());
    } catch (error) {
      onError(error);
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    await _subscription?.cancel();
  }
}
