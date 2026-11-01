import 'package:backlog_core/backlog_core.dart' show ConfigDraft, ConfigEditor, DiffKind;
import 'package:dart_tui/dart_tui.dart';

import 'screen.dart';

/// One entry of a [MenuScreen]; disabled entries say why in their
/// [detail] and cannot be chosen.
final class MenuEntry {
  const MenuEntry(this.label, {this.detail, this.onSelect, this.enabled = true});

  final String label;
  final String? detail;
  final bool enabled;

  /// Pushes the next screen or returns work for [Navigator.task].
  final Cmd? Function(Navigator navigator)? onSelect;
}

const _listStyles = FullListStyles(
  selectedTitle: Style(isReverse: true),
  description: Style(isDim: true),
  cursor: Style(isBold: true),
  filterPrompt: Style(isBold: true),
  statusBar: Style(isDim: true),
  noResults: Style(isDim: true),
);

/// A `dart_tui` [ListModel] of entries with their details: ↑/↓ (j/k),
/// PgUp/PgDn and Home/End move, `/` filters, Enter or → chooses; Escape,
/// ← or `q` go back.
class MenuScreen extends Screen {
  MenuScreen(this.title, {List<MenuEntry> Function()? entries, List<String> Function()? intro})
    : _entries = entries,
      _intro = intro;

  @override
  final String title;

  final List<MenuEntry> Function()? _entries;
  final List<String> Function()? _intro;
  ListModel _list = ListModel(items: const [], showStatusBar: false, styles: _listStyles);
  List<MenuEntry> _shown = const [];

  /// The entries, built anew for every frame so that they can show state.
  List<MenuEntry> get entries => _entries?.call() ?? const [];

  /// Lines above the entries.
  List<String> get intro => _intro?.call() ?? const [];

  /// The list in sync with [entries], [height] rows high.
  ListModel _synced(int height) {
    _shown = entries;
    final items = [
      for (final entry in _shown)
        ListItem(title: entry.label, description: entry.detail ?? '', filterValue: entry.label),
    ];
    return _list = ListModel(
      items: items,
      cursor: _list.selectedIndex,
      height: height,
      filter: _list.filter,
      filterMode: _list.filterMode,
      showStatusBar: false,
      styles: _listStyles,
    );
  }

  int _height = 10;

  @override
  String get hints => _list.filterMode
      ? 'type to filter · Enter done · Esc clear'
      : '↑↓ move · Enter choose · / filter · Esc back · q quit';

  @override
  List<String> body(int width, int height) {
    final header = [...intro, if (intro.isNotEmpty) ''];
    // Two rows per entry (label and detail).
    _height = ((height - header.length - 2) ~/ 2).clamp(1, 1 << 20);
    return [...header, ..._lines(_synced(_height).view().content)];
  }

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    final list = _synced(_height);
    final filtering = list.filterMode;
    if (msg is KeyMsg && !filtering) {
      switch (msg.key) {
        case 'enter' || 'right':
          final selected = list.selected;
          if (selected == null) return null;
          return _choose(_shown[list.items.indexOf(selected)], navigator);
        case 'esc' when list.filter.isEmpty:
          navigator.leave();
          return null;
        case 'left':
          navigator.leave();
          return null;
        case 'q':
          navigator.leaveAll();
          return null;
        case 'tab':
          return _move('down');
      }
    }
    final (next, cmd) = list.update(msg);
    _list = next as ListModel;
    return cmd;
  }

  Cmd? _move(String key) {
    final (next, _) = _list.update(KeyPressMsg(TeaKey(code: key == 'down' ? KeyCode.down : KeyCode.up)));
    _list = next as ListModel;
    return null;
  }

  Cmd? _choose(MenuEntry entry, Navigator navigator) {
    if (!entry.enabled || entry.onSelect == null) {
      navigator.say(entry.detail ?? 'Not available.', error: true);
      return null;
    }
    return entry.onSelect!(navigator);
  }
}

/// A question answered with `y` or `n` (Escape means no).
final class ConfirmScreen extends Screen {
  ConfirmScreen(this.title, this.question, {required this.onYes, this.onNo});

  @override
  final String title;
  final String question;
  final Apply onYes;
  final Apply? onNo;

  @override
  String get hints => 'y yes · n no';

  @override
  List<String> body(int width, int height) => [question];

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    if (msg is! KeyMsg) return null;
    switch (msg.key) {
      case 'y' || 'Y':
        navigator.pop();
        onYes(navigator);
      case 'n' || 'N' || 'esc':
        navigator.pop();
        onNo?.call(navigator);
    }
    return null;
  }
}

/// One line of text in a `dart_tui` [TextInputModel] (←/→, Home/End,
/// readline keys); Enter submits, Escape cancels.
final class PromptScreen extends Screen {
  PromptScreen(this.title, this.label, {String initial = '', this.help = const [], required this.onSubmit})
    : _input = TextInputModel(value: initial, styles: const InputStyles()).moveToEnd();

  @override
  final String title;
  final String label;
  final List<String> help;

  /// Called with the text after the prompt is popped.
  final Cmd? Function(String text, Navigator navigator) onSubmit;

  TextInputModel _input;

  String get text => _input.value;

  static const _prompt = '> ';

  @override
  String get hints => 'Enter confirm · Esc cancel';

  @override
  List<String> body(int width, int height) => [
    label,
    '$_prompt${_input.view().content}',
    if (help.isNotEmpty) '',
    for (final line in help) Look.dim(line),
  ];

  @override
  Cursor? get cursor => switch (_input.view().cursor) {
    final cursor? => Cursor(x: _prompt.length + cursor.x, y: 1, shape: cursor.shape),
    null => null,
  };

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    if (msg is KeyMsg) {
      switch (msg.key) {
        case 'enter':
          navigator.pop();
          return onSubmit(text, navigator);
        case 'esc':
          navigator.pop();
          return null;
      }
    }
    final (next, cmd) = _input.update(msg);
    _input = next as TextInputModel;
    return cmd;
  }
}

/// Read-only lines in a `dart_tui` [ViewportModel] (↑/↓, PgUp/PgDn,
/// Home/End); Escape, ← or `q` go back.
class TextScreen extends Screen {
  TextScreen(this.title, this._source);

  @override
  final String title;
  final List<String> Function() _source;
  ViewportModel? _viewport;

  @override
  String get hints => '↑↓ PgUp PgDn scroll · Esc back';

  List<String> get lines => _source();

  @override
  List<String> body(int width, int height) {
    final content = lines.join('\n');
    final previous = _viewport;
    final viewport = previous == null || previous.width != width || previous.height != height
        ? ViewportModel(
            content: content,
            width: width,
            height: height,
            softWrap: false,
            yOffset: previous?.yOffset ?? 0,
          )
        : previous.setContent(content);
    _viewport = viewport;
    return _lines(viewport.view().content);
  }

  /// Scrolls for the movement keys; true when [msg] was one of them.
  bool scroll(Msg msg) {
    final viewport = _viewport;
    if (viewport == null || msg is! KeyMsg) return false;
    if (!const {'up', 'down', 'k', 'j', 'pgup', 'pgdown', 'space', 'home', 'end', 'g', 'G'}.contains(msg.key)) {
      return false;
    }
    final (next, _) = viewport.update(msg);
    _viewport = next as ViewportModel;
    return true;
  }

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    if (scroll(msg)) return null;
    if (msg is KeyMsg && const {'esc', 'left', 'q'}.contains(msg.key)) navigator.leave();
    return null;
  }
}

/// The diff of [draft] against the file, whether it is valid, and saving
/// with `y` (or `s`); `n` or Escape go back with the edits kept, `d`
/// discards them. The shared last step of every edit.
final class ReviewScreen extends TextScreen {
  ReviewScreen(this.editor, this.draft, {required this.onSaved}) : super('Review changes', () => const []);

  final ConfigEditor editor;
  final ConfigDraft draft;

  /// Called with the saved draft after a successful save.
  final void Function(ConfigDraft saved) onSaved;

  @override
  String get hints => draft.changed
      ? (editor.problem(draft) == null ? 'y save · n back · d discard · ↑↓ scroll' : 'n back · d discard · ↑↓ scroll')
      : 'Esc back';

  @override
  List<String> get lines {
    if (!draft.changed) return ['No changes to ${editor.location}.'];
    final problem = editor.problem(draft);
    return [
      'Changes to ${editor.location}:',
      '',
      for (final line in draft.diff)
        switch (line.kind) {
          DiffKind.added => Look.green(line.marked),
          DiffKind.removed => Look.red(line.marked),
          DiffKind.skipped => Look.cyan(line.marked),
          DiffKind.same => line.marked,
        },
      '',
      if (problem == null) Look.green('Valid. Save?') else Look.red('Cannot save: $problem'),
    ];
  }

  @override
  Cmd? update(Msg msg, Navigator navigator) {
    if (scroll(msg) || msg is! KeyMsg) return null;
    switch (msg.key) {
      case 'y' || 's' when draft.changed:
        // A failure keeps this screen and the draft, with the message.
        return Navigator.task(() async {
          final saved = await editor.save(draft);
          return (navigator) {
            navigator
              ..pop()
              ..say('Saved ${editor.location}.');
            onSaved(saved);
          };
        });
      case 'd' when draft.changed:
        draft.reset();
        navigator
          ..pop()
          ..say('Changes discarded.');
      case 'n' || 'esc' || 'left':
        navigator.pop();
    }
    return null;
  }
}

/// The lines of a component's rendered view, without the trailing newline.
List<String> _lines(String content) {
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
