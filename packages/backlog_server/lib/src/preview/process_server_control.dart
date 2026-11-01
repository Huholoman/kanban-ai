import 'dart:async';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';

/// Restarts this server process as another program (a preview build, or
/// back to main): a detached helper waits until this process has ended,
/// then starts [restart]'s program with the same [arguments], working
/// folder and [environment], its output appended to [log]. The new server
/// runs detached from the terminal; agents and commands the old one started
/// keep running and the new one finds them.
final class ProcessServerControl implements ServerControl {
  ProcessServerControl({
    required this.program,
    required this.arguments,
    required Map<String, String> environment,
    required this.log,
    required Future<void> Function() stop,
    String? workingDirectory,
    Duration probeTimeout = const Duration(seconds: 20),
    int? processId,
  }) : _environment = environment,
       _pid = processId ?? pid,
       _stop = stop,
       _workingDirectory = workingDirectory ?? Directory.current.path,
       _probeTimeout = probeTimeout;

  /// Set for a restarted server: the program it was started as.
  static const programVariable = 'KANBAN_AI_SERVER_PROGRAM';

  /// Set for a server restarted for a preview: its commit.
  static const previewVariable = 'KANBAN_AI_PREVIEW';

  /// The program a server with [environment] was started as:
  /// [programVariable], else [fallback] (how it was started by hand).
  static String programOf(Map<String, String> environment, String fallback) {
    final named = environment[programVariable];
    return named == null || named.isEmpty ? fallback : named;
  }

  /// Waits until the process `$1` has ended, then runs the rest as the new
  /// server with its output appended to the log `$2`.
  static const _helper =
      r'pid=$1; log=$2; shift 2; '
      r'while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done; '
      r'printf "\n# kanban-ai: restarting the server as %s at %s\n" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"; '
      r'exec "$@" </dev/null >>"$log" 2>&1';

  @override
  final String program;

  /// The server's command-line arguments.
  final List<String> arguments;

  /// Where a restarted server writes its output.
  final String log;

  final Map<String, String> _environment;
  final Future<void> Function() _stop;
  final String _workingDirectory;
  final Duration _probeTimeout;

  /// The process the helper waits for (this one).
  final int _pid;

  @override
  String? get preview {
    final commit = _environment[previewVariable];
    return commit == null || commit.isEmpty ? null : commit;
  }

  /// The environment of the new server: this one's, without the web app the
  /// old build's wrapper set (each build brings its own; `--web` among the
  /// [arguments] still applies) and with [programVariable] and
  /// [previewVariable] for the new one.
  Map<String, String> environmentFor(String program, {String? preview}) => {
    for (final MapEntry(:key, :value) in _environment.entries)
      if (key != 'BACKLOG_WEB' && key != previewVariable) key: value,
    programVariable: program,
    previewVariable: ?preview,
  };

  @override
  Future<String?> problemWith(String program) async {
    try {
      final result = await Process.run(
        program,
        const ['--help'],
        environment: environmentFor(program),
        includeParentEnvironment: false,
        workingDirectory: _workingDirectory,
      ).timeout(_probeTimeout);
      return result.exitCode == 0 ? null : '`$program --help` exited with code ${result.exitCode}';
    } on ProcessException catch (error) {
      return 'cannot run $program: ${error.message}';
    } on TimeoutException {
      return '`$program --help` did not end within ${_probeTimeout.inSeconds} s';
    }
  }

  @override
  Future<void> restart(String program, {String? preview}) async {
    await File(log).parent.create(recursive: true);
    await Process.start(
      'sh',
      ['-c', _helper, 'kanban-ai-restart', '$_pid', log, program, ...arguments],
      environment: environmentFor(program, preview: preview),
      includeParentEnvironment: false,
      workingDirectory: _workingDirectory,
      mode: ProcessStartMode.detached,
    );
    await _stop();
  }
}
