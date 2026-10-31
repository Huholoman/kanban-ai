import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

/// Follows the log of one item's agent like `tail -f`: [poll] reports what
/// was appended since the previous call, formatted for people
/// ([AgentLogFormatter]), and switches to a new log when a new run starts.
///
/// Only complete lines are reported while the agent runs (a line still
/// being written waits for its newline); after the run everything is.
final class AgentLogFollower {
  AgentLogFollower(this._source, {required this.item, this.lines = 200, this.window = 512 * 1024});

  /// Where the log is now (the launcher's `agentLogSource`).
  final Future<AgentLogSource?> Function() _source;
  final String item;

  /// How many formatted lines the first message (and a reset) carries.
  final int lines;

  /// At most this many bytes from the end of the file are read for a reset.
  final int window;

  bool _started = false;
  String? _path;
  int _offset = 0;
  bool _running = false;
  AgentLogFormatter _formatter = const PlainLogFormatter();

  /// The next message, or null when nothing changed. The first call always
  /// answers (a reset, with no path when no agent has run yet).
  Future<AgentLogUpdateDto?> poll() async {
    final source = await _source();
    if (source == null) {
      if (_started && _path == null) return null;
      _started = true;
      _path = null;
      _running = false;
      return AgentLogUpdateDto(item: item, reset: true);
    }
    final length = await _length(source.path);
    if (!_started || source.path != _path || length < _offset) return _reset(source, length);

    final changed = source.running != _running;
    _running = source.running;
    final appended = length > _offset ? await _consume(source.path, _offset, length, all: !source.running) : null;
    final formatted = appended == null ? const <String>[] : _formatter.formatAll(appended);
    if (formatted.isEmpty && !changed) return null;
    return _update(source, formatted);
  }

  /// Polls every [interval] and emits the messages until cancelled.
  Stream<AgentLogUpdateDto> follow({Duration interval = const Duration(milliseconds: 500)}) {
    late final StreamController<AgentLogUpdateDto> controller;
    Timer? timer;
    var busy = false;
    Future<void> tick() async {
      if (busy) return;
      busy = true;
      try {
        if (await poll() case final update? when !controller.isClosed) controller.add(update);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        busy = false;
      }
    }

    controller = StreamController(
      onListen: () {
        unawaited(tick());
        timer = Timer.periodic(interval, (_) => unawaited(tick()));
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  Future<AgentLogUpdateDto> _reset(AgentLogSource source, int length) async {
    _started = true;
    _path = source.path;
    _running = source.running;
    _formatter = AgentLogFormatter.forOutput(source.output);
    final start = max(0, length - window);
    _offset = start;
    var raw = await _consume(source.path, start, length, all: !source.running) ?? const <String>[];
    if (start > 0 && raw.isNotEmpty) raw = raw.sublist(1); // the first line is cut
    final formatted = _formatter.formatAll(raw);
    return _update(
      source,
      formatted.length <= lines ? formatted : formatted.sublist(formatted.length - lines),
      reset: true,
    );
  }

  AgentLogUpdateDto _update(AgentLogSource source, List<String> formatted, {bool reset = false}) => AgentLogUpdateDto(
    item: item,
    path: source.path,
    running: source.running,
    reset: reset,
    lines: formatted,
    last: source.last == null ? null : AgentRunEndDto.fromJson(source.last!),
  );

  /// The lines in bytes [from]..[to] of [path], up to the last newline
  /// unless [all]; advances the offset past what was taken.
  Future<List<String>?> _consume(String path, int from, int to, {required bool all}) async {
    final RandomAccessFile file;
    try {
      file = await File(path).open();
    } on FileSystemException {
      return null;
    }
    try {
      await file.setPosition(from);
      final bytes = await file.read(to - from);
      var end = bytes.length;
      if (!all) {
        end = bytes.lastIndexOf(0x0a) + 1;
        if (end == 0) return null;
      }
      _offset = from + end;
      var text = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
      if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
      if (text.isEmpty) return null;
      return [for (final line in text.split('\n')) line.endsWith('\r') ? line.substring(0, line.length - 1) : line];
    } finally {
      await file.close();
    }
  }

  static Future<int> _length(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return 0;
    }
  }
}

/// `WS …/dispatch/log/<item>/live`: sends the [AgentLogFollower]'s messages
/// as JSON text frames until the client goes away.
Handler agentLogSocketHandler(AgentLogFollower follower, {Duration interval = const Duration(milliseconds: 500)}) =>
    webSocketHandler((channel, _) {
      final subscription = follower
          .follow(interval: interval)
          .listen((update) => channel.sink.add(jsonEncode(update.toJson())), onError: (Object _) {});
      channel.stream.listen(null, onDone: subscription.cancel, onError: (Object _) => subscription.cancel());
    }, pingInterval: const Duration(seconds: 30));
