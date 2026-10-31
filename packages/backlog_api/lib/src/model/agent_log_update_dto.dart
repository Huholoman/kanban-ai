import 'dispatch_dto.dart';
import 'json.dart';

/// One message of a followed agent log (`WS /api/dispatch/log/<item>/live`):
/// readable lines (Claude's stream-json condensed, other output as it is)
/// appended since the previous message, or with [reset] the tail of a log
/// to show instead of everything before (first message, a new run).
final class AgentLogUpdateDto {
  const AgentLogUpdateDto({
    required this.item,
    this.path,
    this.running = false,
    this.reset = false,
    this.lines = const [],
    this.last,
  });

  factory AgentLogUpdateDto.fromJson(Json json) => AgentLogUpdateDto(
    item: json.string('item'),
    path: json.optionalString('path'),
    running: json.boolean('running'),
    reset: json.boolean('reset'),
    lines: json.strings('lines'),
    last: switch (json.optionalObject('last')) {
      final last? => AgentRunEndDto.fromJson(last),
      null => null,
    },
  );

  static const type = 'agent-log';

  final String item;

  /// The log file on the server; null while no agent has run for [item].
  final String? path;

  /// An agent runs for [item] now.
  final bool running;

  /// [lines] replace what was shown before.
  final bool reset;
  final List<String> lines;

  /// How the last run ended; null while running and before any run.
  final AgentRunEndDto? last;

  Json toJson() => {
    'type': type,
    'item': item,
    'path': path,
    'running': running,
    'reset': reset,
    'lines': lines,
    'last': last?.toJson(),
  };
}
