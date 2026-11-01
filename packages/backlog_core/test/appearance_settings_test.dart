import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

const _config = '''
statuses:
  - {id: todo, category: open, pickable: true}
  - {id: doing, category: active}
  - {id: done, category: done}
# Colours of the board.
appearance:
  mode: dark   # the team likes it dark
  statuses: {todo: "#1e88e5"}
''';

void main() {
  test('reads and edits the mode, palettes and value colours', () {
    final settings = AppearanceSettings(ConfigDraft(_config));
    expect(settings.mode, 'dark');
    expect(settings.colors('statuses'), {'todo': '#1e88e5'});
    settings
      ..setMode('light')
      ..setPaletteColor('light', 'seed', '3f51b5')
      ..setPaletteColor('dark', 'background', '#123')
      ..setColor('statuses', 'doing', '#FB8C00')
      ..setColor('labels', 'infra', '#00897b')
      ..setColor('statuses', 'todo', '');
    expect(settings.draft.text, contains('mode: light   # the team likes it dark'));
    expect(settings.draft.text, contains('# Colours of the board.'));
    final appearance = parseWorkflowYaml(settings.draft.text).appearance;
    expect(appearance.mode, 'light');
    expect(appearance.light.seed, '#3f51b5');
    expect(appearance.dark.background, '#112233');
    expect(appearance.statuses, {'doing': '#fb8c00'});
    expect(appearance.labels, {'infra': '#00897b'});
    expect(settings.paletteColor('light', 'seed'), '#3f51b5');

    settings
      ..setMode('system')
      ..setPaletteColor('light', 'seed', ' ');
    expect(settings.draft.valueAt(['appearance', 'mode']), isNull);
    expect(settings.paletteColor('light', 'seed'), isNull);
    expect(() => settings.setColor('statuses', 'doing', 'orange'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setMode('dim'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setColor('columns', 'a', '#fff'), throwsA(isA<InvalidInputException>()));
    expect(rgbOf('#fb8c00'), (251, 140, 0));
    expect(rgbOf('fb8c00'), isNull);
  });

  test('a file without appearance gets one', () {
    final settings = AppearanceSettings(ConfigDraft(''))..setColor('priorities', 'p0', '#e53935');
    expect(parseWorkflowYaml(settings.draft.text).appearance.priorities, {'p0': '#e53935'});
  });
}
