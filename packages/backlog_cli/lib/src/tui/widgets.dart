import 'package:backlog_core/backlog_core.dart';

import 'keys.dart';
import 'screen.dart';

/// One line of a [MenuScreen]; disabled entries are shown dimmed with
/// their [detail] and cannot be chosen.
final class MenuEntry {
  const MenuEntry(this.label, {this.detail, this.onSelect, this.enabled = true});

  final String label;
  final String? detail;
  final bool enabled;
  final Future<void> Function(Navigator navigator)? onSelect;
}

/// A list to move through with ↑/↓ (or j/k) and choose with Enter (or →);
/// Escape, ← or `q` go back.
class MenuScreen extends Screen {
  MenuScreen(this.title, {List<MenuEntry> Function()? entries, List<String> Function()? intro})
    : _entries = entries,
      _intro = intro;

  @override
  final String title;

  final List<MenuEntry> Function()? _entries;
  final List<String> Function()? _intro;
  int selected = 0;

  /// The entries, built anew for every frame so that they can show state.
  List<MenuEntry> get entries => _entries?.call() ?? const [];

  /// Lines above the entries.
  List<String> get intro => _intro?.call() ?? const [];

  @override
  String get hints => '↑↓ move · Enter choose · Esc back · q quit';

  @override
  List<String> body(int width, int height) {
    final entries = this.entries;
    if (entries.isNotEmpty) selected = selected.clamp(0, entries.length - 1);
    final labelWidth = entries.fold(0, (w, e) => e.label.length > w ? e.label.length : w);
    final header = [for (final line in intro) Style.fit(line, width), if (intro.isNotEmpty) ''];
    final room = height - header.length;
    final first = room <= 0 || selected < room ? 0 : selected - room + 1;
    return [
      ...header,
      for (final (index, entry) in entries.indexed.skip(first).take(room < 1 ? 1 : room))
        _row(entry, index == selected, labelWidth, width),
    ];
  }

  String _row(MenuEntry entry, bool current, int labelWidth, int width) {
    final text = Style.fit(
      '${current ? '›' : ' '} ${entry.label.padRight(labelWidth)}${entry.detail == null ? '' : '  ${entry.detail}'}',
      width,
      pad: current,
    );
    if (current) return Style.reverse(text);
    return entry.enabled ? text : Style.dim(text);
  }

  @override
  Future<void> handle(Key key, Navigator navigator) async {
    final entries = this.entries;
    switch (key.kind) {
      case KeyKind.up:
        selected = entries.isEmpty ? 0 : (selected - 1) % entries.length;
      case KeyKind.down || KeyKind.tab:
        selected = entries.isEmpty ? 0 : (selected + 1) % entries.length;
      case KeyKind.home:
        selected = 0;
      case KeyKind.end:
        selected = entries.isEmpty ? 0 : entries.length - 1;
      case KeyKind.enter || KeyKind.right:
        if (selected < entries.length) await _choose(entries[selected], navigator);
      case KeyKind.escape || KeyKind.left:
        await navigator.leave();
      case KeyKind.char when key.char == 'k':
        selected = entries.isEmpty ? 0 : (selected - 1) % entries.length;
      case KeyKind.char when key.char == 'j':
        selected = entries.isEmpty ? 0 : (selected + 1) % entries.length;
      case KeyKind.char when key.char == 'q':
        await quitAll(navigator);
      default:
    }
  }

  Future<void> _choose(MenuEntry entry, Navigator navigator) async {
    if (!entry.enabled || entry.onSelect == null) {
      navigator.say(entry.detail ?? 'Not available.', error: true);
      return;
    }
    await entry.onSelect!(navigator);
  }
}

/// Leaves screen after screen while each agrees ([Screen.mayLeave]); stops
/// at the first one that does not.
Future<void> quitAll(Navigator navigator) async {
  while (await navigator.top.mayLeave(navigator)) {
    if (navigator.stack.length == 1) {
      navigator.quit();
      return;
    }
    await navigator.pop();
  }
}

/// A question answered with `y` or `n` (Escape means no).
final class ConfirmScreen extends Screen {
  ConfirmScreen(this.title, this.question, {required this.onYes, this.onNo});

  @override
  final String title;
  final String question;
  final Future<void> Function(Navigator navigator) onYes;
  final Future<void> Function(Navigator navigator)? onNo;

  @override
  String get hints => 'y yes · n no';

  @override
  List<String> body(int width, int height) => [Style.fit(question, width)];

  @override
  Future<void> handle(Key key, Navigator navigator) async {
    if (key.isChar('y') || key.isChar('Y')) {
      await navigator.pop();
      await onYes(navigator);
    } else if (key.isChar('n') || key.isChar('N') || key.kind == KeyKind.escape) {
      await navigator.pop();
      await onNo?.call(navigator);
    }
  }
}

/// One line of text to edit: ←/→, Home/End, Backspace/Delete; Enter
/// submits, Escape cancels.
final class PromptScreen extends Screen {
  PromptScreen(this.title, this.label, {String initial = '', this.help = const [], required this.onSubmit})
    : _text = initial.runes.toList(),
      _cursor = initial.runes.length;

  @override
  final String title;
  final String label;
  final List<String> help;

  /// Called with the text after the prompt is popped.
  final Future<void> Function(String text, Navigator navigator) onSubmit;

  final List<int> _text;
  int _cursor;

  String get text => String.fromCharCodes(_text);

  @override
  String get hints => 'Enter confirm · Esc cancel';

  @override
  List<String> body(int width, int height) {
    final before = String.fromCharCodes(_text.take(_cursor));
    final at = _cursor < _text.length ? String.fromCharCode(_text[_cursor]) : ' ';
    final after = _cursor < _text.length ? String.fromCharCodes(_text.skip(_cursor + 1)) : '';
    return [
      Style.fit(label, width),
      '> $before${Style.reverse(at)}$after',
      if (help.isNotEmpty) '',
      for (final line in help) Style.dim(Style.fit(line, width)),
    ];
  }

  @override
  Future<void> handle(Key key, Navigator navigator) async {
    switch (key.kind) {
      case KeyKind.char:
        final runes = key.char!.runes;
        _text.insertAll(_cursor, runes);
        _cursor += runes.length;
      case KeyKind.backspace when _cursor > 0:
        _text.removeAt(--_cursor);
      case KeyKind.delete when _cursor < _text.length:
        _text.removeAt(_cursor);
      case KeyKind.left when _cursor > 0:
        _cursor--;
      case KeyKind.right when _cursor < _text.length:
        _cursor++;
      case KeyKind.home:
        _cursor = 0;
      case KeyKind.end:
        _cursor = _text.length;
      case KeyKind.enter:
        await navigator.pop();
        await onSubmit(text, navigator);
      case KeyKind.escape:
        await navigator.pop();
      default:
    }
  }
}

/// Read-only lines to scroll through (↑/↓, PgUp/PgDn, Home/End).
class TextScreen extends Screen {
  TextScreen(this.title, this._lines);

  @override
  final String title;
  final List<String> Function() _lines;
  int offset = 0;
  int _height = 10;

  @override
  String get hints => '↑↓ PgUp PgDn scroll · Esc back';

  List<String> get lines => _lines();

  @override
  List<String> body(int width, int height) {
    _height = height;
    final lines = this.lines;
    offset = offset.clamp(0, lines.length > height ? lines.length - height : 0);
    return [for (final line in lines.skip(offset).take(height)) line];
  }

  /// Scrolls for the movement keys; true when [key] was one of them.
  bool scroll(Key key) {
    switch (key.kind) {
      case KeyKind.up:
        offset--;
      case KeyKind.down:
        offset++;
      case KeyKind.pageUp:
        offset -= _height;
      case KeyKind.pageDown:
        offset += _height;
      case KeyKind.char when key.char == ' ':
        offset += _height;
      case KeyKind.home:
        offset = 0;
      case KeyKind.end:
        offset = 1 << 30;
      default:
        return false;
    }
    if (offset < 0) offset = 0;
    return true;
  }

  @override
  Future<void> handle(Key key, Navigator navigator) async {
    if (scroll(key)) return;
    if (key.kind == KeyKind.escape || key.kind == KeyKind.left || key.isChar('q')) await navigator.leave();
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
  final Future<void> Function(ConfigDraft saved, Navigator navigator) onSaved;

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
          DiffKind.added => Style.green(line.marked),
          DiffKind.removed => Style.red(line.marked),
          DiffKind.skipped => Style.cyan(line.marked),
          DiffKind.same => line.marked,
        },
      '',
      if (problem == null) Style.green('Valid. Save?') else Style.red('Cannot save: $problem'),
    ];
  }

  @override
  List<String> body(int width, int height) => [for (final line in super.body(width, height)) _cut(line, width)];

  /// Diff lines are styled whole; cut the visible text only.
  static String _cut(String line, int width) {
    final match = RegExp(r'^(\x1b\[\d+m)(.*)(\x1b\[\d+m)$').firstMatch(line);
    if (match == null) return Style.fit(line, width);
    return '${match[1]}${Style.fit(match[2]!, width)}${match[3]}';
  }

  @override
  Future<void> handle(Key key, Navigator navigator) async {
    if (scroll(key)) return;
    if ((key.isChar('y') || key.isChar('s')) && draft.changed) {
      final saved = await editor.save(draft); // a BacklogException keeps the screen, with the message
      await navigator.pop();
      navigator.say('Saved ${editor.location}.');
      await onSaved(saved, navigator);
    } else if (key.isChar('d') && draft.changed) {
      draft.reset();
      await navigator.pop();
      navigator.say('Changes discarded.');
    } else if (key.isChar('n') || key.kind == KeyKind.escape || key.kind == KeyKind.left) {
      await navigator.pop();
    }
  }
}
