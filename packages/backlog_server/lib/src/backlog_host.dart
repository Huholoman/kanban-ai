import 'package:backlog_core/backlog_core.dart';

/// Keeps the opened [Backlog] of one [BacklogStorage] and reopens it after
/// the configuration changes, so that edits of the workflow apply without a
/// restart.
///
/// The storage may cache what it read (a folder caches parsed item files,
/// validated by `stat` on every read, see `FileSystemItemRepository`);
/// reopening the backlog drops that cache.
final class BacklogHost {
  BacklogHost(this.storage, {this.clock = const SystemClock()});

  /// The backlog folder at [root], caching parsed items ([FileBacklogStorage]).
  BacklogHost.folder(String root, {Clock clock = const SystemClock()})
    : this(FileBacklogStorage(root, cacheItems: true), clock: clock);

  final BacklogStorage storage;
  final Clock clock;
  Future<Backlog>? _current;

  /// The folder of the backlog (see [BacklogStorage.root]).
  String get root => storage.root;

  Future<Backlog> get backlog => _current ??= _open();

  Future<Backlog> _open() async {
    try {
      return await Backlog.connect(storage, clock: clock);
    } catch (_) {
      // A broken configuration must not stay cached once it is fixed.
      _current = null;
      rethrow;
    }
  }

  /// Forgets the opened backlog; the next access reads the configuration again.
  void reload() => _current = null;
}
