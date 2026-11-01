/// The local preview the board's server runs now (the built-in action
/// `preview`): which item's branch, at which commit (rebased onto [base]),
/// since when, and which server program "Back to main" restarts with.
/// One per server; a new preview replaces it.
final class PreviewState {
  const PreviewState({
    required this.project,
    required this.item,
    required this.title,
    required this.branch,
    required this.commit,
    required this.base,
    required this.since,
    required this.server,
    required this.mainServer,
  });

  factory PreviewState.fromJson(Map<String, Object?> json) => PreviewState(
    project: json['project']! as String,
    item: json['item']! as String,
    title: json['title'] as String? ?? '',
    branch: json['branch']! as String,
    commit: json['commit']! as String,
    base: json['base'] as String? ?? 'main',
    since: DateTime.parse(json['since']! as String),
    server: json['server']! as String,
    mainServer: json['main_server']! as String,
  );

  /// The project (registry id) whose item it shows.
  final String project;
  final String item;
  final String title;
  final String branch;

  /// The commit the preview was built from: [branch] rebased onto [base].
  final String commit;
  final String base;
  final DateTime since;

  /// The server program the preview runs as.
  final String server;

  /// The server program "Back to main" restarts the board with.
  final String mainServer;

  Map<String, Object?> toJson() => {
    'project': project,
    'item': item,
    'title': title,
    'branch': branch,
    'commit': commit,
    'base': base,
    'since': since.toUtc().toIso8601String(),
    'server': server,
    'main_server': mainServer,
  };
}

/// Where the current [PreviewState] is kept (a file in the dispatcher's
/// state folder, shared by every project of the server).
abstract interface class PreviewStore {
  /// The current preview; null when the server runs its main build.
  Future<PreviewState?> read();

  Future<void> write(PreviewState state);

  Future<void> clear();
}

/// The running server, as far as actions may control it: they may replace
/// it with another build of itself.
abstract interface class ServerControl {
  /// The program this server was started as (e.g. `backlog-server`).
  String get program;

  /// The preview this server was started for ([restart] with `preview`):
  /// the [PreviewState.commit]; null for a server started otherwise.
  String? get preview;

  /// Whether [program] can start a server here (found and runnable);
  /// null when it can, else why not.
  Future<String?> problemWith(String program);

  /// Starts [program] with this server's arguments and environment once
  /// this server has stopped (marked as running [preview], when given),
  /// then stops this one. Agents and detached commands keep running.
  Future<void> restart(String program, {String? preview});
}
