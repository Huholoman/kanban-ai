/// A run of a global command of the server (`commands` in `server.yaml`):
/// running until [finished], then succeeded ([exitCode] 0) or failed (a
/// non-zero [exitCode], or [error] when it could not start or the restart
/// after it could not). [output] is what it printed (stdout and stderr
/// together, its end when it is long).
final class CommandRun {
  const CommandRun({
    required this.name,
    required this.started,
    this.finished,
    this.exitCode,
    this.output = '',
    this.error,
    this.restart,
  });

  final String name;
  final DateTime started;

  /// When it ended; null while it runs.
  final DateTime? finished;

  /// The exit code of the command; null while it runs or when it did not
  /// start.
  final int? exitCode;
  final String output;

  /// Why it failed other than by its exit code.
  final String? error;

  /// The program the server restarts as after this run succeeded; null
  /// when it does not restart (or not yet: only set once the restart is
  /// under way).
  final String? restart;

  bool get running => finished == null;

  bool get succeeded => finished != null && exitCode == 0 && error == null;
}
