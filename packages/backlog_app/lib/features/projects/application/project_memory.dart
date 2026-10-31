/// Remembers the project this viewer opened last, so that the next visit
/// without a project in the URL opens it again, and the view last chosen in
/// each project, so that coming back to a project shows it again. A
/// convenience only: it may forget at any time.
abstract interface class ProjectMemory {
  String? read();

  void write(String id);

  /// The view last chosen in [project] (null: the single backlog).
  String? readView(String? project);

  void writeView(String? project, String view);
}

/// Keeps the last project and views for the lifetime of the app (tests,
/// desktop).
final class InMemoryProjectMemory implements ProjectMemory {
  InMemoryProjectMemory([this._id, Map<String?, String>? views]) : _views = {...?views};

  String? _id;
  final Map<String?, String> _views;

  @override
  String? read() => _id;

  @override
  void write(String id) => _id = id;

  @override
  String? readView(String? project) => _views[project];

  @override
  void writeView(String? project, String view) => _views[project] = view;
}
