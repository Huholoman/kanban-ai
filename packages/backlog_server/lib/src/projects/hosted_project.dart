import 'dart:async';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';

import '../backlog_host.dart';
import '../events/change_feed.dart';
import '../events/event_socket.dart';
import '../http/api_handler.dart';

/// How live projects are run; shared by every project of a server.
final class ProjectRuntime {
  const ProjectRuntime({
    this.clock = const SystemClock(),
    this.debounce = const Duration(milliseconds: 150),
    this.dispatchDebounce = const Duration(milliseconds: 500),
    this.launcher,
    this.log,
    this.prefixLogs = false,
  });

  final Clock clock;

  /// Collects bursts of file events into one change event.
  final Duration debounce;
  final Duration dispatchDebounce;

  /// Receives the dispatcher's assignments; null logs what would start.
  final AgentLauncher? launcher;
  final void Function(String message)? log;

  /// Whether log lines start with `[<project id>] ` (several projects).
  final bool prefixLogs;
}

/// One backlog of the server: its [BacklogHost], the watcher that feeds change
/// events and the dispatcher, and the API answering under its prefix.
///
/// A project whose folder is missing or whose `backlog.yaml` is broken is
/// still hosted: its requests fail with the backlog's error, and it starts
/// watching as soon as the folder exists ([ensureStarted]).
final class HostedProject {
  /// A project that watches its folder and runs a dispatcher.
  HostedProject.live(this.entry, ProjectRuntime runtime)
    : _runtime = runtime,
      host = BacklogHost(entry.path, clock: runtime.clock);

  /// A project fed by [events] instead of a watcher, without a dispatcher.
  HostedProject.fixed(this.entry, this.host, {Stream<BacklogChangeEvent> events = const Stream.empty()})
    : _runtime = null {
    _fixed = events.listen(_events.add);
  }

  /// The registry entry; replaced when only its name changes.
  ProjectEntry entry;
  final BacklogHost host;
  final ProjectRuntime? _runtime;
  final _events = StreamController<BacklogChangeEvent>.broadcast();
  StreamSubscription<BacklogChangeEvent>? _fixed;
  ChangeFeed? _feed;
  Dispatcher? _dispatcher;
  Future<void>? _starting;
  bool _closed = false;
  late final Handler _api = ApiHandler(host).handler;
  late final Handler _socket = eventSocketHandler(_events.stream);

  String get id => entry.id;

  /// Change events of this project (relative paths inside its folder).
  Stream<BacklogChangeEvent> get events => _events.stream;

  /// Plans ready work of this project; null until it is watched (and for
  /// [HostedProject.fixed]).
  Dispatcher? get dispatcher => _dispatcher;

  /// The API of this project, for requests whose `url` is relative to its
  /// prefix (`items`, `events`, …).
  Handler get handler => (request) async {
    await ensureStarted();
    return request.url.path == 'events' ? _socket(request) : _api(request);
  };

  /// Starts watching and dispatching once the folder exists; cheap when it
  /// already runs.
  Future<void> ensureStarted() async {
    final runtime = _runtime;
    if (runtime == null || _feed != null || _closed) return;
    final starting = _starting ??= _start(runtime);
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _start(ProjectRuntime runtime) async {
    if (!await Directory(host.root).exists()) return;
    final feed = ChangeFeed(host.root, debounce: runtime.debounce);
    await feed.start();
    if (_closed) {
      await feed.close();
      return;
    }
    final say = _say(runtime);
    final dispatcher = Dispatcher(
      snapshot: () async => (await host.backlog).planning.snapshot(),
      backlogRoot: host.root,
      launcher: runtime.launcher ?? LoggingLauncher(say),
      clock: runtime.clock,
      debounce: runtime.dispatchDebounce,
      onError: (error, _) => say('Dispatcher: $error'),
    );
    dispatcher.plans.listen((plan) => say(describePlan(plan)));
    feed.events.listen((event) {
      if (event.paths.contains(BacklogLayout.configFileName)) host.reload();
      dispatcher.notifyChanged();
      if (!_events.isClosed) _events.add(event);
    });
    _feed = feed;
    _dispatcher = dispatcher;
    unawaited(dispatcher.evaluate());
  }

  void Function(String) _say(ProjectRuntime runtime) {
    final log = runtime.log;
    if (log == null) return (_) {};
    return runtime.prefixLogs ? (message) => log('[$id] $message') : log;
  }

  /// Why the backlog cannot be used now, or null when it opens.
  Future<String?> problem() async {
    if (!await Directory(host.root).exists()) return 'Folder ${host.root} does not exist.';
    try {
      await host.backlog;
      return null;
    } on BacklogException catch (error) {
      return error.message;
    }
  }

  Future<ProjectDto> describe() async {
    await ensureStarted();
    return ProjectDto(id: id, name: entry.displayName, path: host.root, error: await problem());
  }

  /// Stops watching and dispatching; open event sockets are closed.
  Future<void> close() async {
    _closed = true;
    await _starting;
    await _fixed?.cancel();
    await _dispatcher?.close();
    await _feed?.close();
    await _events.close();
  }

  /// One log line about a new [plan].
  static String describePlan(DispatchPlan? plan) {
    if (plan == null) return 'Dispatcher: off (no dispatcher section in backlog.yaml).';
    final verb = plan.mode == DispatchMode.auto ? 'starts' : 'proposes';
    final assignments = plan.assignments.map((a) => '${a.id} → ${a.agent}').join(', ');
    return 'Dispatcher (${plan.mode.name}): ${plan.running}/${plan.config.maxAgents} running; '
        '${assignments.isEmpty ? 'nothing to start' : '$verb $assignments'}'
        '${plan.waiting.isEmpty ? '' : '; ${plan.waiting.length} ready item(s) waiting'}.';
  }
}
