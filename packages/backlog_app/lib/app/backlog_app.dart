import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../features/board/presentation/board_page.dart';
import '../features/dashboard/application/dashboard_controller.dart';
import '../features/projects/application/project_memory.dart';
import '../features/projects/application/project_route.dart';
import '../features/projects/application/projects_controller.dart';
import '../shared/tokens.dart';
import '../shared/ui/ui.dart';
import 'app_scope.dart';
import 'appearance_controller.dart';

/// The app: loads the server's projects and shows the open one. Each
/// project gets its own [_ProjectSession] (API, theme, board, detail, live
/// updates); switching projects disposes the old session as a whole, so
/// nothing of one project leaks into the other.
class BacklogApp extends StatefulWidget {
  const BacklogApp({
    super.key,
    this.projects,
    this.api,
    this.config = const AppConfig(),
    this.memory,
    this.initialRoute,
  }) : assert(projects != null || api != null, 'Needs projects or a single backlog.');

  /// The server's projects; null for a single backlog ([api]).
  final ProjectsApi? projects;

  /// The backlog on the unprefixed paths: the only one without [projects],
  /// the fallback for a server that does not know projects with them.
  final BacklogApi? api;
  final AppConfig config;

  /// Where the last opened project is remembered.
  final ProjectMemory? memory;

  /// Route the page was opened with (`/p/<id>` names the project); by
  /// default the platform's (on the web the URL fragment).
  final String? initialRoute;

  @override
  State<BacklogApp> createState() => _BacklogAppState();
}

class _BacklogAppState extends State<BacklogApp> with WidgetsBindingObserver {
  late final _projects = ProjectsController(
    widget.projects,
    fallback: widget.api,
    memory: widget.memory,
    requested: ProjectRoute.parse(widget.initialRoute ?? WidgetsBinding.instance.platformDispatcher.defaultRouteName),
  );

  /// Watches every project, whichever is open.
  late final DashboardController _dashboard;

  @override
  void initState() {
    super.initState();
    // Registered before the MaterialApp, so a URL typed in the address bar
    // reaches this observer first.
    WidgetsBinding.instance.addObserver(this);
    _dashboard = DashboardController(_projects, agent: widget.config.agent);
    unawaited(_projects.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dashboard.dispose();
    _projects.dispose();
    super.dispose();
  }

  /// The URL changed outside the app (edited, a link): open its project.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    if (ProjectRoute.parse(routeInformation.uri.path) case final id?) _projects.select(id);
    return true;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _projects,
    builder: (context, _) => switch (_projects.api) {
      final api? => _ProjectSession(
        key: ObjectKey(api),
        api: api,
        projects: _projects,
        dashboard: _dashboard,
        config: widget.config,
      ),
      null => _ProjectsStatus(controller: _projects),
    },
  );
}

/// One open project: its API in [AppScope], its theme and the board.
class _ProjectSession extends StatefulWidget {
  const _ProjectSession({
    super.key,
    required this.api,
    required this.projects,
    required this.dashboard,
    required this.config,
  });

  final BacklogApi api;
  final ProjectsController projects;
  final DashboardController dashboard;
  final AppConfig config;

  @override
  State<_ProjectSession> createState() => _ProjectSessionState();
}

class _ProjectSessionState extends State<_ProjectSession> {
  late final _appearance = AppearanceController(widget.api);

  /// Named after the project, so that the Navigator puts it into the URL.
  late final _route = switch (widget.projects.current) {
    final project? => ProjectRoute.of(project.id),
    null => ProjectRoute.single,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_appearance.start());
  }

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  Route<void> _board() => MaterialPageRoute<void>(
    settings: RouteSettings(name: _route),
    builder: (_) => const BoardPage(),
  );

  @override
  Widget build(BuildContext context) => AppScope(
    api: widget.api,
    config: widget.config,
    appearance: _appearance,
    projects: widget.projects,
    dashboard: widget.dashboard,
    child: ListenableBuilder(
      listenable: Listenable.merge([_appearance, widget.dashboard]),
      builder: (context, _) => MaterialApp(
        title: switch ((widget.projects.current?.name ?? 'Backlog', widget.dashboard.needsMe)) {
          (final name, 0) => name,
          (final name, final count) => '($count) $name',
        },
        debugShowCheckedModeBanner: false,
        theme: _appearance.theme(Brightness.light),
        darkTheme: _appearance.theme(Brightness.dark),
        themeMode: _appearance.mode,
        // Theme loads after the first frame; switch at once instead of fading.
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => _LargeScreenText(child: child!),
        onGenerateInitialRoutes: (_) => [_board()],
        onGenerateRoute: (settings) => settings.name == _route ? _board() : null,
      ),
    ),
  );
}

/// Before a project is open: loading, the projects failed to load, or none
/// of them can be opened.
class _ProjectsStatus extends StatelessWidget {
  const _ProjectsStatus({required this.controller});

  final ProjectsController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Backlog',
    debugShowCheckedModeBanner: false,
    theme: BoardTokens.light.toTheme(Brightness.light),
    darkTheme: BoardTokens.dark.toTheme(Brightness.dark),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: controller.loading ? const CircularProgressIndicator() : _message(context),
        ),
      ),
    ),
  );

  Widget _message(BuildContext context) {
    final error = controller.error;
    final unauthorized = error is BacklogApiException && error.type == 'unauthorized';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(error == null ? Icons.folder_off_outlined : Icons.cloud_off, size: 48),
        const SizedBox(height: 12),
        if (error != null) Text('$error', textAlign: TextAlign.center),
        if (unauthorized) const Text('Open the URL printed by the server, including ?token=…'),
        if (error == null) ...[
          Text(
            controller.projects.isEmpty ? 'The server has no projects.' : 'No project can be opened.',
            textAlign: TextAlign.center,
          ),
          for (final project in controller.projects)
            Text('${project.name}: ${project.error}', textAlign: TextAlign.center),
        ],
        const SizedBox(height: 12),
        PrimaryButton(label: 'Retry', onPressed: controller.start),
      ],
    );
  }
}

/// Scales text up on very wide screens (27" 4K and similar), where 13 px
/// would read small from the usual distance; the user's own scaling applies
/// on top.
class _LargeScreenText extends StatelessWidget {
  const _LargeScreenText({required this.child});

  /// From this logical width text is [factor] times larger.
  static const wideWidth = 2000.0;
  static const factor = 1.15;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width < wideWidth) return child;
    return MediaQuery(
      data: media.copyWith(textScaler: _Scaled(media.textScaler)),
      child: child,
    );
  }
}

class _Scaled extends TextScaler {
  const _Scaled(this.inner);

  final TextScaler inner;

  @override
  double scale(double fontSize) => inner.scale(fontSize) * _LargeScreenText.factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => inner.textScaleFactor * _LargeScreenText.factor;
}
