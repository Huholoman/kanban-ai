import 'package:backlog_core/backlog_core.dart';

import 'keys.dart';
import 'terminal.dart';

/// ANSI styling of single lines; [fit] cuts text to the screen width
/// before it is styled, so that escape sequences never get cut.
abstract final class Style {
  static String bold(String text) => '\x1b[1m$text\x1b[22m';
  static String dim(String text) => '\x1b[2m$text\x1b[22m';
  static String reverse(String text) => '\x1b[7m$text\x1b[27m';
  static String red(String text) => '\x1b[31m$text\x1b[39m';
  static String green(String text) => '\x1b[32m$text\x1b[39m';
  static String yellow(String text) => '\x1b[33m$text\x1b[39m';
  static String cyan(String text) => '\x1b[36m$text\x1b[39m';

  /// [text] cut (with `…`) or padded to [width] characters.
  static String fit(String text, int width, {bool pad = false}) {
    final runes = text.replaceAll('\t', '  ').runes.toList();
    if (runes.length > width) {
      return width <= 0 ? '' : '${String.fromCharCodes(runes.take(width - 1))}…';
    }
    return pad ? text.replaceAll('\t', '  ').padRight(width) : text.replaceAll('\t', '  ');
  }
}

/// One page of the TUI. The [Navigator] draws the breadcrumb, the [body] and
/// the [hints] line and hands key presses to [handle].
abstract class Screen {
  /// The page's name in the breadcrumb.
  String get title;

  /// The key hints in the bottom line.
  String get hints;

  /// The lines between the breadcrumb and the hints, cut to [width]; at
  /// most [height] of them are shown.
  List<String> body(int width, int height);

  /// Reacts to [key]; may push or pop screens through [navigator].
  Future<void> handle(Key key, Navigator navigator);

  /// Asked before the screen is popped (Escape, `q`); false keeps it, e.g.
  /// to ask about unsaved changes first.
  Future<bool> mayLeave(Navigator navigator) async => true;

  /// Called when the screen is shown again after the one above it was
  /// popped, e.g. to re-read state.
  Future<void> resumed(Navigator navigator) async {}
}

/// The stack of screens and the loop that draws them and feeds them keys.
final class Navigator {
  Navigator(this._terminal, Screen root) : _stack = [root];

  final Terminal _terminal;
  final List<Screen> _stack;
  String? _message;
  bool _messageIsError = false;
  bool _done = false;

  List<Screen> get stack => List.unmodifiable(_stack);

  Screen get top => _stack.last;

  void push(Screen screen) => _stack.add(screen);

  /// Pops the top screen (unless it is the root, which quits) without
  /// asking [Screen.mayLeave].
  Future<void> pop() async {
    if (_stack.length == 1) {
      _done = true;
      return;
    }
    _stack.removeLast();
    await top.resumed(this);
  }

  /// Pops the top screen when it agrees ([Screen.mayLeave]).
  Future<void> leave() async {
    if (await top.mayLeave(this)) await pop();
  }

  /// Ends the loop.
  void quit() => _done = true;

  /// Shows [text] in the status line until the next key.
  void say(String text, {bool error = false}) {
    _message = text;
    _messageIsError = error;
  }

  /// Runs until the root is left, the input ends or Ctrl+C.
  Future<void> run() async {
    _terminal.open();
    try {
      _draw();
      await for (final key in _terminal.keys) {
        _message = null;
        if (key.kind == KeyKind.interrupt) break;
        try {
          await top.handle(key, this);
        } on BacklogException catch (e) {
          say(e.message, error: true);
        }
        if (_done) break;
        _draw();
      }
    } finally {
      _terminal.close();
    }
  }

  void _draw() {
    final width = _terminal.width;
    final height = _terminal.height;
    final crumbs = [for (final screen in _stack) screen.title].join(' › ');
    final bodyHeight = height - 4;
    final body = top.body(width, bodyHeight < 1 ? 1 : bodyHeight);
    final lines = [Style.bold(Style.fit(crumbs, width)), '', ...body.take(bodyHeight < 1 ? 1 : bodyHeight)];
    while (lines.length < height - 2) {
      lines.add('');
    }
    final message = _message;
    lines
      ..add(
        message == null
            ? ''
            : (_messageIsError ? Style.red(Style.fit(message, width)) : Style.green(Style.fit(message, width))),
      )
      ..add(Style.dim(Style.fit(top.hints, width)));
    _terminal.draw(lines);
  }
}
