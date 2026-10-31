import 'dart:async';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'http/client_filter.dart';
import 'http/middleware.dart';
import 'http/web_app.dart';
import 'projects/hosted_project.dart';
import 'projects/project_hub.dart';
import 'projects/registry_watcher.dart';

/// Composition root of the server: the API, change events and the static web
/// app in front of the backlogs of the project registry, or of one folder.
final class BacklogServer {
  BacklogServer._(this._servers, this.projects, this._registryWatcher);

  /// Starts serving on each of [addresses] (all on the same port). Port 0
  /// picks a free port (see [uri]). With [allow], only clients from these
  /// ranges get an answer other than 403.
  ///
  /// Serves either the one backlog at [root] (it must open, or the start
  /// fails) or every project of the registry in [projectsFile] (see
  /// `YamlProjectRegistryStore`; [home] expands `~/`), which is watched:
  /// projects added or removed there start and stop without a restart, and
  /// broken ones are served with their error. Only a malformed registry
  /// fails the start.
  ///
  /// Each project's dispatcher re-plans after every change (debounced by
  /// [dispatchDebounce]) and, in auto mode, hands assignments to [launcher];
  /// without one it only logs what it would start.
  static Future<BacklogServer> start({
    String? root,
    String? projectsFile,
    String? home,
    List<Object> addresses = const ['0.0.0.0'],
    int port = 8640,
    String? token,
    List<AddressRange>? allow,
    String? webRoot,
    Clock clock = const SystemClock(),
    Duration debounce = const Duration(milliseconds: 150),
    void Function(String message)? log,
    AgentLauncher? launcher,
    Duration dispatchDebounce = const Duration(milliseconds: 500),
  }) async {
    if ((root == null) == (projectsFile == null)) {
      throw ArgumentError('Give either root or projectsFile.');
    }
    final runtime = ProjectRuntime(
      clock: clock,
      debounce: debounce,
      dispatchDebounce: dispatchDebounce,
      launcher: launcher,
      log: log,
      prefixLogs: projectsFile != null,
    );
    final hub = ProjectHub((entry) => HostedProject.live(entry, runtime));
    RegistryWatcher? watcher;
    try {
      if (root != null) {
        final entry = ProjectEntry.at(BacklogLayout(root).root);
        await Backlog.open(entry.path, clock: clock); // fail fast on a missing or broken backlog
        await hub.sync(ProjectRegistry([entry]));
      } else {
        final store = YamlProjectRegistryStore(projectsFile!, home: home);
        await hub.sync(await store.load());
        watcher = RegistryWatcher(
          store,
          debounce: debounce,
          onChange: (registry) async {
            await hub.sync(registry);
            log?.call('Projects: ${describeProjects(hub)}');
          },
          onError: (error) => log?.call('Project registry ${store.file} not applied: $error'),
        );
        await watcher.start();
      }
    } catch (_) {
      await watcher?.close();
      await hub.close();
      rethrow;
    }

    final handler = buildHandler(projects: hub, token: token, allow: allow, webRoot: webRoot, log: log);
    final servers = <HttpServer>[];
    try {
      for (final address in addresses) {
        // The first bind settles a free port that the others then share.
        servers.add(await shelf_io.serve(handler, address, servers.isEmpty ? port : servers.first.port));
      }
    } catch (_) {
      for (final server in servers) {
        await server.close(force: true);
      }
      await watcher?.close();
      await hub.close();
      rethrow;
    }
    return BacklogServer._(servers, hub, watcher);
  }

  /// One log line about a new [plan].
  static String describePlan(DispatchPlan? plan) => HostedProject.describePlan(plan);

  /// The hosted project ids, the default one marked.
  static String describeProjects(ProjectHub hub) => hub.projects.isEmpty
      ? '(none)'
      : [for (final (i, project) in hub.projects.indexed) i == 0 ? '${project.id} (default)' : project.id].join(', ');

  /// The whole request pipeline, without sockets, for tests.
  static Handler buildHandler({
    required ProjectHub projects,
    String? token,
    List<AddressRange>? allow,
    String? webRoot,
    void Function(String message)? log,
  }) {
    final api = projects.handler;
    final web = webRoot != null && Directory(webRoot).existsSync() ? webAppHandler(webRoot) : null;

    FutureOr<Response> route(Request request) {
      if (request.url.path.startsWith('api/')) return api(request);
      if (web != null) return web(request);
      return Response.notFound('No web app built; run `flutter build web` in packages/backlog_app.');
    }

    var pipeline = const Pipeline();
    if (log != null) pipeline = pipeline.addMiddleware(logRequests(logger: (message, _) => log(message)));
    if (allow != null) pipeline = pipeline.addMiddleware(allowClients(allow));
    pipeline = pipeline.addMiddleware(allowCrossOrigin());
    if (token != null) pipeline = pipeline.addMiddleware(requireToken(token));
    return pipeline.addHandler(route);
  }

  final List<HttpServer> _servers;
  final RegistryWatcher? _registryWatcher;

  /// The hosted projects; the first one answers the unprefixed paths.
  final ProjectHub projects;

  /// The first bound address.
  Uri get uri => uris.first;

  List<Uri> get uris => [
    for (final server in _servers) Uri(scheme: 'http', host: server.address.host, port: server.port),
  ];

  int get port => _servers.first.port;

  Future<void> close() async {
    for (final server in _servers) {
      await server.close(force: true);
    }
    await _registryWatcher?.close();
    await projects.close();
  }
}
