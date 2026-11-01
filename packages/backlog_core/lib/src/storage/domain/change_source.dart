/// One batch of changes of a backlog, by whoever made them (this process,
/// agents, editors, git).
final class StorageChange {
  const StorageChange(this.paths, {this.configuration = false});

  /// What changed, sorted: paths relative to the backlog for a folder
  /// (`items/T-1-a.md`, `.locks/T-1.lock`), keys of the same shape for other
  /// storages, so that clients can tell items, claims and views apart.
  final List<String> paths;

  /// Whether the workflow configuration changed (open the backlog again).
  final bool configuration;
}

/// Port: reports the changes of a backlog (a folder watcher, database
/// notifications, …). Bursts are reported as one [StorageChange].
abstract interface class ChangeSource {
  /// Changes since [start]; a broadcast stream.
  Stream<StorageChange> get changes;

  /// Completes once changes made from now on are reported.
  Future<void> start();

  /// Stops reporting and closes [changes].
  Future<void> close();
}
