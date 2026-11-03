import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

/// The global commands of the server (`commands` in `server.yaml`, e.g.
/// "Update") for the command menu at the top right, whichever project is
/// open: asked for at [start] and [refresh]ed when the menu opens; while a
/// command runs, its run is asked for every [every] until it ends.
class CommandsController extends ChangeNotifier {
  CommandsController(this._api, {this.every = const Duration(seconds: 1)});

  /// Null for a single backlog without projects: there are no commands then.
  final ProjectsApi? _api;
  final Duration every;
  Timer? _timer;
  bool _disposed = false;

  List<ServerCommandDto> commands = const [];

  /// The running command or the one that ran last.
  CommandRunDto? run;

  /// Why starting a command failed.
  String? error;

  bool get running => run?.running ?? false;

  Future<void> start() => refresh();

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    CommandsDto listed;
    try {
      listed = await api.commands();
    } catch (_) {
      return; // restarting, unreachable, or an older server: keep what we know
    }
    if (_disposed) return;
    commands = listed.commands;
    run = listed.run;
    _follow();
    notifyListeners();
  }

  /// Starts command [name]; false when the server refused ([error]).
  Future<bool> runCommand(String name) async {
    final api = _api;
    if (api == null) return false;
    error = null;
    try {
      run = await api.runCommand(name);
      return true;
    } on BacklogApiException catch (e) {
      error = e.message;
      return false;
    } catch (e) {
      error = '$e';
      return false;
    } finally {
      if (!_disposed) {
        _follow();
        notifyListeners();
      }
    }
  }

  /// Polls while a command runs.
  void _follow() {
    if (!running) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(every, (_) => unawaited(refresh()));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
