import '../../shared/errors.dart';

/// Colours of the app in one brightness. Every colour is optional: [seed]
/// generates a whole palette, the others override parts of it.
final class Palette {
  const Palette({this.seed, this.primary, this.secondary, this.background});

  static const none = Palette();

  final String? seed;
  final String? primary;
  final String? secondary;

  /// Page and panel background.
  final String? background;

  bool get isEmpty => seed == null && primary == null && secondary == null && background == null;
}

/// How the web board looks: light and dark palettes, the default mode and
/// colours of statuses, priorities, types and labels. The core only keeps
/// and validates it (colours are `#rrggbb`); drawing is up to the clients.
final class Appearance {
  const Appearance({
    this.mode = 'system',
    this.light = Palette.none,
    this.dark = Palette.none,
    this.statuses = const {},
    this.priorities = const {},
    this.types = const {},
    this.labels = const {},
  });

  static const none = Appearance();

  static const modes = ['system', 'light', 'dark'];

  /// `system`, `light` or `dark`; the app can still switch.
  final String mode;
  final Palette light;
  final Palette dark;

  /// Colour by status / priority / type / label value.
  final Map<String, String> statuses;
  final Map<String, String> priorities;
  final Map<String, String> types;
  final Map<String, String> labels;

  /// [value] as `#rrggbb`: accepts `#rgb`, `#rrggbb` and the same without
  /// `#` (in YAML `#…` must be quoted, otherwise it is a comment).
  static String color(Object value, String path) {
    var text = '$value'.trim().toLowerCase();
    if (text.startsWith('#')) text = text.substring(1);
    if (RegExp(r'^[0-9a-f]{3}$').hasMatch(text)) text = text.split('').map((c) => '$c$c').join();
    if (!RegExp(r'^[0-9a-f]{6}$').hasMatch(text)) {
      throw ConfigurationException('"$path" must be a colour like "#3f51b5", got "$value".');
    }
    return '#$text';
  }
}
