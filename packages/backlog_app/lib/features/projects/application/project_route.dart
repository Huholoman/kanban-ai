/// The project in the page URL: the route `/p/<id>` (on the web the part
/// after `#`, so `?token=…` stays where it is and the server needs no
/// routes of its own).
abstract final class ProjectRoute {
  /// Route of the default project on a server without projects.
  static const single = '/';

  static String of(String id) => '/p/${Uri.encodeComponent(id)}';

  /// The project id in [route], or null when it names none.
  static String? parse(String route) {
    final segments = Uri.tryParse(route)?.pathSegments ?? const [];
    return segments.length == 2 && segments.first == 'p' && segments.last.isNotEmpty ? segments.last : null;
  }
}
