import 'dart:async';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'backlog_host.dart';
import 'events/change_feed.dart';
import 'events/event_socket.dart';
import 'http/api_handler.dart';
import 'http/client_filter.dart';
import 'http/middleware.dart';
import 'http/web_app.dart';

/// Composition root of the server: the API, change events and the static web
/// app in front of one backlog folder.
final class BacklogServer {
  BacklogServer._(this._servers, this._feed, this.host, this.dispatcher);

  /// Starts serving [root] on each of [addresses] (all on the same port).
  /// Port 0 picks a free port (see [uri]). With [allow], only clients from
  /// these ranges get an answer other than 403.
  ///
  /// The [dispatcher] re-plans after every change (debounced by
  /// [dispatchDebounce]) and, in auto mode, hands assignments to [launcher];
  /// without one it only logs what it would start.
  static Future<BacklogServer> start({
    required String root,
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
    final host = BacklogHost(root, clock: clock);
    await host.backlog; // fail fast on a missing or broken backlog
    final feed = ChangeFeed(host.root, debounce: debounce);
    await feed.start();
    final say = log ?? (_) {};
    final dispatcher = Dispatcher(
      snapshot: () async => (await host.backlog).planning.snapshot(),
      backlogRoot: host.root,
      launcher: launcher ?? LoggingLauncher(say),
      clock: clock,
      debounce: dispatchDebounce,
      onError: (error, _) => say('Dispatcher: $error'),
    );
    dispatcher.plans.listen((plan) => say(describePlan(plan)));
    feed.events.listen((event) {
      if (event.paths.contains(BacklogLayout.configFileName)) host.reload();
      dispatcher.notifyChanged();
    });
    unawaited(dispatcher.evaluate());

    final handler = buildHandler(
      host: host,
      events: feed.events,
      token: token,
      allow: allow,
      webRoot: webRoot,
      log: log,
    );
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
      await dispatcher.close();
      await feed.close();
      rethrow;
    }
    return BacklogServer._(servers, feed, host, dispatcher);
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

  /// The whole request pipeline, without sockets, for tests.
  static Handler buildHandler({
    required BacklogHost host,
    required Stream<BacklogChangeEvent> events,
    String? token,
    List<AddressRange>? allow,
    String? webRoot,
    void Function(String message)? log,
  }) {
    final api = ApiHandler(host).handler;
    final socket = eventSocketHandler(events);
    final web = webRoot != null && Directory(webRoot).existsSync() ? webAppHandler(webRoot) : null;

    FutureOr<Response> route(Request request) {
      final path = request.url.path;
      if (path == ApiPaths.events.substring(1)) return socket(request);
      if (path.startsWith('api/')) return api(request);
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
  final ChangeFeed _feed;
  final BacklogHost host;

  /// Plans ready work for the worktrees in `backlog.yaml` (idle without a
  /// `dispatcher` section).
  final Dispatcher dispatcher;

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
    await dispatcher.close();
    await _feed.close();
  }
}
