import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/backlog_app.dart';
import 'app/project_memory_store.dart';

/// Served by backlog_server, the app talks to the origin it was loaded from.
/// Query parameters: `token` (if the server needs one), `as` (agent name for
/// claims) and `server` (another API address, e.g. during `flutter run`).
/// The open project is the route after `#`: `/#/p/<id>`.
void main() {
  final query = Uri.base.queryParameters;
  final server = query['server'] ?? const String.fromEnvironment('BACKLOG_SERVER');
  final base = server.isNotEmpty ? Uri.parse(server) : Uri.base.replace(path: '/', query: '', fragment: '');
  final token = query['token'] == null || query['token']!.isEmpty ? null : query['token'];
  final agent = query['as'];
  runApp(
    BacklogApp(
      projects: HttpProjectsApi(base, token: token),
      // A server without projects serves its one backlog on the old paths.
      api: HttpBacklogApi(base, token: token),
      memory: projectMemoryStore(),
      config: AppConfig(agent: agent == null || agent.isEmpty ? null : agent),
    ),
  );
}
