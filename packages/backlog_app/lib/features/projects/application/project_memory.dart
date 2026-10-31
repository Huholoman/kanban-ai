/// Remembers the project this viewer opened last, so that the next visit
/// without a project in the URL opens it again. A convenience only: it may
/// forget at any time.
abstract interface class ProjectMemory {
  String? read();

  void write(String id);
}

/// Keeps the last project for the lifetime of the app (tests, desktop).
final class InMemoryProjectMemory implements ProjectMemory {
  InMemoryProjectMemory([this._id]);

  String? _id;

  @override
  String? read() => _id;

  @override
  void write(String id) => _id = id;
}
