import 'dart:async';
import 'dart:io';

import 'keys.dart';

/// What the TUI needs from a terminal; [IoTerminal] is the real one, tests
/// use a fake.
abstract interface class Terminal {
  int get width;
  int get height;

  /// Key presses, from [open] on.
  Stream<Key> get keys;

  /// Takes over the screen: raw input, alternate screen, hidden cursor.
  void open();

  /// Shows [lines] as the whole screen.
  void draw(List<String> lines);

  /// Gives the screen back as it was.
  void close();
}

/// The process's own terminal through `dart:io`: raw mode on stdin (no
/// echo, no line buffering), ANSI sequences on stdout. Ctrl+C arrives as
/// [KeyKind.interrupt] instead of killing the process, so that the
/// terminal is always restored.
final class IoTerminal implements Terminal {
  IoTerminal({Stdin? input, Stdout? output}) : _in = input ?? stdin, _out = output ?? stdout;

  final Stdin _in;
  final Stdout _out;
  final _keys = StreamController<Key>();
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool? _echo;
  bool? _lineMode;

  /// Whether stdin and stdout are both a terminal.
  static bool get available => stdin.hasTerminal && stdout.hasTerminal;

  @override
  int get width => _out.hasTerminal ? _out.terminalColumns : 80;

  @override
  int get height => _out.hasTerminal ? _out.terminalLines : 24;

  @override
  Stream<Key> get keys => _keys.stream;

  @override
  void open() {
    _echo = _in.echoMode;
    _lineMode = _in.lineMode;
    _in
      ..echoMode = false
      ..lineMode = false;
    _subscriptions
      ..add(_in.listen((bytes) => decodeKeys(bytes).forEach(_keys.add), onDone: _keys.close))
      ..add(ProcessSignal.sigint.watch().listen((_) => _keys.add(const Key(KeyKind.interrupt))));
    if (!Platform.isWindows) {
      // A resize redraws with the new size.
      _subscriptions.add(ProcessSignal.sigwinch.watch().listen((_) => _keys.add(const Key(KeyKind.unknown))));
    }
    _out.write('\x1b[?1049h\x1b[?25l');
  }

  @override
  void draw(List<String> lines) {
    final buffer = StringBuffer('\x1b[H');
    for (final (index, line) in lines.indexed) {
      if (index > 0) buffer.write('\r\n');
      buffer
        ..write(line)
        ..write('\x1b[0m\x1b[K');
    }
    buffer.write('\x1b[J');
    _out.write(buffer);
  }

  @override
  void close() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _out.write('\x1b[0m\x1b[?25h\x1b[?1049l');
    if (_lineMode case final lineMode?) _in.lineMode = lineMode;
    if (_echo case final echo?) _in.echoMode = echo;
  }
}
