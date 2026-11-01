import '../../shared/errors.dart';
import '../../workflow/domain/appearance.dart';
import 'config_draft.dart';

/// Typed reads and edits of `appearance` in a `backlog.yaml` [draft] (§2):
/// the mode, the light and dark palettes and the colours of statuses,
/// priorities, types and labels. Colours are checked and written as
/// `"#rrggbb"`; an empty input removes the key.
final class AppearanceSettings {
  AppearanceSettings(this.draft);

  final ConfigDraft draft;

  /// The palettes (`light`, `dark`) and their keys.
  static const palettes = ['light', 'dark'];
  static const paletteKeys = ['seed', 'primary', 'secondary', 'background'];

  /// The groups of value colours.
  static const groups = ['statuses', 'priorities', 'types', 'labels'];

  String get mode => '${draft.valueAt(['appearance', 'mode']) ?? 'system'}';

  void setMode(String mode) {
    if (!Appearance.modes.contains(mode)) {
      throw InvalidInputException('The mode is one of ${Appearance.modes.join(', ')}, not "$mode".');
    }
    if (mode == 'system') {
      draft.remove(['appearance', 'mode']);
    } else {
      draft.set(['appearance', 'mode'], mode);
    }
  }

  /// Colour [key] of [palette] as written, null when absent.
  String? paletteColor(String palette, String key) {
    _check(palettes, palette, 'palette');
    _check(paletteKeys, key, 'palette colour');
    return _color(draft.valueAt(['appearance', palette, key]));
  }

  /// Sets colour [key] of [palette]; returns it as written (`#rrggbb`),
  /// null when removed.
  String? setPaletteColor(String palette, String key, String input) {
    _check(palettes, palette, 'palette');
    _check(paletteKeys, key, 'palette colour');
    return _setColor(['appearance', palette, key], input);
  }

  /// The colours of [group] by value, as written.
  Map<String, String> colors(String group) {
    _check(groups, group, 'group');
    final map = draft.valueAt(['appearance', group]);
    if (map is! Map) return const {};
    return {for (final MapEntry(:key, :value) in map.entries) '$key': ?_color(value)};
  }

  /// Sets the colour of [value] in [group]; returns it as written, null
  /// when removed.
  String? setColor(String group, String value, String input) {
    _check(groups, group, 'group');
    if (value.trim().isEmpty) throw const InvalidInputException('Give the value to colour.');
    return _setColor(['appearance', group, value.trim()], input);
  }

  String? _setColor(List<Object> path, String input) {
    if (input.trim().isEmpty) {
      draft.remove(path);
      return null;
    }
    final String color;
    try {
      color = Appearance.color(input, path.join('.'));
    } on ConfigurationException catch (e) {
      throw InvalidInputException(e.message);
    }
    draft.set(path, color);
    return color;
  }

  /// [value] as `#rrggbb` when it is a colour, else as written (null when
  /// absent).
  static String? _color(Object? value) {
    if (value == null) return null;
    try {
      return Appearance.color(value, '');
    } on ConfigurationException {
      return '$value';
    }
  }

  static void _check(List<String> known, String value, String what) {
    if (!known.contains(value)) throw InvalidInputException('Unknown $what "$value".');
  }
}

/// The red, green and blue of a `#rrggbb` [color], null for anything else.
(int, int, int)? rgbOf(String color) {
  final match = RegExp(r'^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$').firstMatch(color);
  if (match == null) return null;
  int part(int group) => int.parse(match[group]!, radix: 16);
  return (part(1), part(2), part(3));
}
