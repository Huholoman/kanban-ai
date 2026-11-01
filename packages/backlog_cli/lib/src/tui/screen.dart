import 'dart:async';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart' show BacklogException;
import 'package:dart_tui/dart_tui.dart';

/// Line styles of the configuration TUI (`dart_tui` [Style]s in the 16
/// basic colours, so that they follow the terminal's theme).
abstract final class Look {
  static String bold(String text) => const Style(isBold: true).render(text);
  static String dim(String text) => const Style(isDim: true).render(text);
  static String reverse(String text) => const Style(isReverse: true).render(text);
  static String red(String text) => const Style(foreground256: 1).render(text);
  static String green(String text) => const Style(foreground256: 2).render(text);
  static String yellow(String text) => const Style(foreground256: 3).render(text);
  static String cyan(String text) => const Style(foreground256: 6).render(text);
}

/// Changes the navigator once asynchronous work (reading or writing a file)
/// is done; see [Navigator.task].
typedef Apply = void Function(Navigator navigator);

/// One page of the TUI. The [Navigator] draws the breadcrumb, the [body] and
/// the [hints] line and hands messages (keys) to [update].
abstract class Screen {
  /// The page's name in the breadcrumb.
  String get title;

  /// The key hints in the bottom line.
  String get hints;

  /// The lines between the breadcrumb and the hints; at most [height] of
  /// them are shown, each cut to [width] by the navigator.
  List<String> body(int width, int height);

  /// Where the terminal cursor goes within [body] (a text input), or null
  /// to keep it hidden.
  Cursor? get cursor => null;

  /// Reacts to [msg], changing this screen or the stack of [navigator];
  /// returns asynchronous work as a [Cmd] (see [Navigator.task]).
  Cmd? update(Msg msg, Navigator navigator);

  /// Asked before the screen is popped (Escape, `q`); false keeps it, e.g.
  /// to ask about unsaved changes first.
  bool mayLeave(Navigator navigator) => true;
}

/// The result of [Navigator.task]: what to change once the work is done.
final class _DoneMsg extends Msg {
  _DoneMsg(this.apply);

  final Apply apply;
}

/// A failure of [Navigator.task], shown in the status line.
final class _FailedMsg extends Msg {
  _FailedMsg(this.message);

  final String message;
}

/// The `dart_tui` model of the TUI: a stack of [Screen]s, the status line
/// and the window size. Keys go to the top screen; Ctrl+C quits at once.
final class Navigator extends Model {
  Navigator(Screen root) : _stack = [root];

  final List<Screen> _stack;
  String? _message;
  bool _messageIsError = false;
  bool _done = false;
  int width = 80;
  int height = 24;

  List<Screen> get stack => List.unmodifiable(_stack);

  Screen get top => _stack.last;

  /// Whether the TUI has ended (the root was left or Ctrl+C).
  bool get done => _done;

  void push(Screen screen) => _stack.add(screen);

  /// Pops the top screen (the root quits) without asking [Screen.mayLeave].
  void pop() {
    if (_stack.length == 1) {
      _done = true;
    } else {
      _stack.removeLast();
    }
  }

  /// Pops the top screen when it agrees ([Screen.mayLeave]).
  void leave() {
    if (top.mayLeave(this)) pop();
  }

  /// Leaves screen after screen while each agrees; stops at the first one
  /// that does not (it may have asked something).
  void leaveAll() {
    while (!_done && top.mayLeave(this)) {
      pop();
    }
  }

  /// Shows [text] in the status line until the next key.
  void say(String text, {bool error = false}) {
    _message = text;
    _messageIsError = error;
  }

  /// Runs [work] (file I/O) outside [update]; its result is applied to the
  /// navigator as a message. A [BacklogException] or [FileSystemException]
  /// ends up in the status line and changes nothing.
  static Cmd task(Future<Apply> Function() work) => () async {
    try {
      return _DoneMsg(await work());
    } on BacklogException catch (e) {
      return _FailedMsg(e.message);
    } on FileSystemException catch (e) {
      return _FailedMsg(_describe(e));
    }
  };

  @override
  (Model, Cmd?) update(Msg msg) {
    Cmd? cmd;
    switch (msg) {
      case WindowSizeMsg(:final width, :final height):
        this.width = width;
        this.height = height;
      case KeyMsg(key: 'ctrl+c'):
        _done = true;
      case _DoneMsg(:final apply):
        _message = null;
        _guard(() => apply(this));
      case _FailedMsg(:final message):
        say(message, error: true);
      case KeyMsg():
        _message = null;
        _guard(() => cmd = top.update(msg, this));
      default:
        _guard(() => cmd = top.update(msg, this));
    }
    return (this, _done ? () => quit() : cmd);
  }

  void _guard(void Function() action) {
    try {
      action();
    } on BacklogException catch (e) {
      say(e.message, error: true);
    } on FileSystemException catch (e) {
      say(_describe(e), error: true);
    }
  }

  static String _describe(FileSystemException e) =>
      '${e.message}${e.path == null ? '' : ': ${e.path}'}${e.osError == null ? '' : ' (${e.osError!.message})'}';

  /// The whole screen as plain lines: breadcrumb, body, status, hints.
  List<String> lines() {
    final crumbs = [for (final screen in _stack) screen.title].join(' › ');
    final bodyHeight = height - 4 < 1 ? 1 : height - 4;
    final body = top.body(width, bodyHeight).take(bodyHeight).toList();
    final message = _message;
    return [
      Look.bold(truncate(crumbs, width)),
      '',
      for (final line in body) truncate(line, width),
      for (var i = body.length; i < bodyHeight; i++) '',
      if (message == null)
        ''
      else
        _messageIsError ? Look.red(truncate(message, width)) : Look.green(truncate(message, width)),
      Look.dim(truncate(top.hints, width)),
    ];
  }

  @override
  View view() {
    final view = newView(lines().join('\n'));
    if (top.cursor case final cursor?) {
      view.cursor = Cursor(x: cursor.x, y: cursor.y + 2, shape: cursor.shape);
    }
    return view;
  }
}
