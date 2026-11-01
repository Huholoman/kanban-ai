import 'package:backlog_core/backlog_core.dart' show AppearanceSettings, WorkflowList, WorkflowSettings, rgbOf;
import 'package:dart_tui/dart_tui.dart' show Cmd, RgbColor, Style;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Appearance*: the colours of the web board in the project's draft —
/// mode, light and dark palettes, colours of statuses, priorities, types and
/// labels — each shown as a swatch in the terminal (true colour).
Screen appearanceScreen(ConfigFileScreen file) {
  AppearanceSettings settings() => AppearanceSettings(file.draft);
  return MenuScreen(
    'Appearance',
    intro: () => [
      if (file.editor.problem(file.draft) case final problem?) Look.red('Not valid: $problem'),
      if (file.draft.changed) Look.yellow('Unsaved changes.'),
      'Only the web board uses these. Colours: #rrggbb (or #rgb).',
      for (final group in AppearanceSettings.groups) ?_preview(file, group),
    ],
    entries: () => [
      MenuEntry(
        'Mode',
        detail: '${settings().mode} (the board can still switch)',
        onSelect: (navigator) => _push(
          navigator,
          MenuScreen(
            'Mode',
            entries: () => [
              for (final mode in const ['system', 'light', 'dark'])
                MenuEntry(
                  mode == settings().mode ? '$mode  ✓' : mode,
                  onSelect: (navigator) {
                    settings().setMode(mode);
                    navigator
                      ..pop()
                      ..say('Mode $mode (not saved yet).');
                    return null;
                  },
                ),
            ],
          ),
        ),
      ),
      for (final palette in AppearanceSettings.palettes)
        MenuEntry(
          '${palette[0].toUpperCase()}${palette.substring(1)} palette',
          detail: [
            for (final key in AppearanceSettings.paletteKeys)
              if (settings().paletteColor(palette, key) case final color?) '$key ${swatch(color)}',
          ].join('  ').ifEmpty('built-in'),
          onSelect: (navigator) => _push(navigator, _paletteScreen(file, palette)),
        ),
      for (final group in AppearanceSettings.groups)
        MenuEntry(
          '${_groupLabel(group)} colours',
          detail: settings().colors(group).isEmpty ? 'built-in' : '${settings().colors(group).length} set',
          onSelect: (navigator) => _push(navigator, _groupScreen(file, group)),
        ),
      MenuEntry(
        'Review and save',
        detail: file.draft.changed ? 'see the changes, then save' : 'no changes',
        onSelect: (navigator) => _push(navigator, file.review()),
      ),
    ],
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

String _groupLabel(String group) => switch (group) {
  'statuses' => 'Status',
  'priorities' => 'Priority',
  'types' => 'Type',
  _ => 'Label',
};

/// A block in [color] followed by its code; `none` without one.
String swatch(String? color) => switch (color == null ? null : rgbOf(color)) {
  (final r, final g, final b) => '${Style(backgroundRgb: RgbColor(r, g, b)).render('    ')} $color',
  null => color ?? 'none',
};

/// The values of [group] that have a colour, each in its colour.
String? _preview(ConfigFileScreen file, String group) {
  final colors = AppearanceSettings(file.draft).colors(group);
  if (colors.isEmpty) return null;
  return '${_groupLabel(group)}: ${[for (final MapEntry(:key, :value) in colors.entries) switch (rgbOf(value)) {
      (final r, final g, final b) => Style(isBold: true, foregroundRgb: RgbColor(r, g, b)).render(key),
      null => key,
    }].join('  ')}';
}

Cmd? _push(Navigator navigator, Screen screen) {
  navigator.push(screen);
  return null;
}

Cmd? _colorPrompt(Navigator navigator, String title, String? current, String? Function(String) apply) => _push(
  navigator,
  PromptScreen(
    title,
    'Colour (#rrggbb or #rgb; empty removes it):',
    initial: current ?? '',
    onSubmit: (text, navigator) {
      final color = apply(text);
      navigator.say(color == null ? '$title removed (not saved yet).' : '$title ${swatch(color)} (not saved yet).');
      return null;
    },
  ),
);

Screen _paletteScreen(ConfigFileScreen file, String palette) {
  AppearanceSettings settings() => AppearanceSettings(file.draft);
  return MenuScreen(
    '${palette[0].toUpperCase()}${palette.substring(1)} palette',
    intro: () => ['The seed generates a whole palette; the others override parts of it.'],
    entries: () => [
      for (final key in AppearanceSettings.paletteKeys)
        MenuEntry(
          key,
          detail: swatch(settings().paletteColor(palette, key)),
          onSelect: (navigator) => _colorPrompt(
            navigator,
            '$palette $key',
            settings().paletteColor(palette, key),
            (text) => settings().setPaletteColor(palette, key, text),
          ),
        ),
    ],
  );
}

/// The colours of one group: the values of the workflow (statuses,
/// priorities, types) or those already coloured (labels), and *Add …*.
Screen _groupScreen(ConfigFileScreen file, String group) {
  AppearanceSettings settings() => AppearanceSettings(file.draft);
  List<String> values() {
    final workflow = WorkflowSettings(file.draft);
    final listed = switch (group) {
      'statuses' => workflow.ids(WorkflowList.statuses),
      'priorities' => workflow.ids(WorkflowList.priorities),
      'types' => workflow.ids(WorkflowList.types),
      _ => const <String>[],
    };
    return [...listed, ...settings().colors(group).keys.where((key) => !listed.contains(key))];
  }

  final label = _groupLabel(group);
  return MenuScreen(
    '$label colours',
    intro: () => ['Values without a colour use the built-in one.'],
    entries: () => [
      for (final value in values())
        MenuEntry(
          value,
          detail: swatch(settings().colors(group)[value]),
          onSelect: (navigator) => _colorPrompt(
            navigator,
            '${label.toLowerCase()} $value',
            settings().colors(group)[value],
            (text) => settings().setColor(group, value, text),
          ),
        ),
      MenuEntry(
        'Add a ${label.toLowerCase()} colour…',
        onSelect: (navigator) => _push(
          navigator,
          PromptScreen(
            'Add a ${label.toLowerCase()} colour',
            '$label to colour:',
            onSubmit: (text, navigator) {
              final value = text.trim();
              return _colorPrompt(
                navigator,
                '${label.toLowerCase()} $value',
                null,
                (color) => settings().setColor(group, value, color),
              );
            },
          ),
        ),
      ),
    ],
  );
}
