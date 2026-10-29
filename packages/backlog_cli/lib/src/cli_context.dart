import 'package:backlog_core/backlog_core.dart';

/// Everything the CLI takes from its process, injectable for tests.
final class CliContext {
  const CliContext({
    required this.out,
    required this.err,
    required this.cwd,
    this.environment = const {},
    this.clock = const SystemClock(),
  });

  final StringSink out;
  final StringSink err;
  final String cwd;
  final Map<String, String> environment;
  final Clock clock;
}
