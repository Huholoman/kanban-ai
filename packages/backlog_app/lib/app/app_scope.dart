import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/widgets.dart';

/// Settings that come from the page URL (`?token=…&as=…&server=…`).
final class AppConfig {
  const AppConfig({this.agent});

  /// Name used when claiming items from the UI; the server decides when null.
  final String? agent;
}

/// Provides the [BacklogApi] and [AppConfig] to the widget tree, so that
/// features get them without global state and tests can pass a fake.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.api, this.config = const AppConfig(), required super.child});

  final BacklogApi api;
  final AppConfig config;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => api != oldWidget.api || config != oldWidget.config;
}
