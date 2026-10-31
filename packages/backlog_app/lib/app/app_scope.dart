import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/widgets.dart';

import '../features/dashboard/application/dashboard_controller.dart';
import '../features/projects/application/projects_controller.dart';
import 'appearance_controller.dart';

/// Settings that come from the page URL (`?token=…&as=…&server=…`).
final class AppConfig {
  const AppConfig({this.agent});

  /// Name used when claiming items from the UI; the server decides when null.
  final String? agent;
}

/// Provides the [BacklogApi] of the open project and [AppConfig] to the widget tree, so that
/// features get them without global state and tests can pass a fake.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    this.config = const AppConfig(),
    this.appearance,
    this.projects,
    this.dashboard,
    required super.child,
  });

  final BacklogApi api;
  final AppConfig config;

  /// Theme from backlog.yaml and the light/dark switch; null in tests that
  /// build a single screen.
  final AppearanceController? appearance;

  /// The server's projects and the open one; null in tests that build a
  /// single screen. [api] belongs to its open project.
  final ProjectsController? projects;

  /// What waits for a person in every project; null in tests that build a
  /// single screen.
  final DashboardController? dashboard;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      api != oldWidget.api ||
      config != oldWidget.config ||
      appearance != oldWidget.appearance ||
      projects != oldWidget.projects ||
      dashboard != oldWidget.dashboard;
}
