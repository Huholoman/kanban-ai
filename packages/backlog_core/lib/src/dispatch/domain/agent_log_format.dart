import 'dart:convert';

import '../../workflow/domain/dispatcher_config.dart';

/// Where the log of an item's agent is and what writes it: the running
/// agent's, else the last run's.
final class AgentLogSource {
  const AgentLogSource({required this.path, required this.running, this.output = AgentOutput.text, this.last});

  /// Absolute path of the log file.
  final String path;

  /// The agent still runs.
  final bool running;

  /// How the agent writes its output; picks the [AgentLogFormatter].
  final AgentOutput output;

  /// How the last run ended (`exit_code`, `reason`, `outcome`, `ended_at`,
  /// `session_id`); null while it runs.
  final Map<String, Object?>? last;
}

/// Turns raw log lines into lines a person can follow. Stateful: feed the
/// lines of one log in order.
abstract class AgentLogFormatter {
  /// The formatter for logs of [output]: Claude's stream-json is condensed,
  /// everything else is shown as it is.
  factory AgentLogFormatter.forOutput(AgentOutput output) => switch (output) {
    AgentOutput.claudeStreamJson => ClaudeStreamJsonFormatter(),
    AgentOutput.text || AgentOutput.jsonLines => const PlainLogFormatter(),
  };

  /// What to show for one raw [line] of the log (nothing, one or several
  /// lines).
  List<String> format(String line);

  /// Formats [lines] one after another.
  List<String> formatAll(Iterable<String> lines) => [for (final line in lines) ...format(line)];
}

/// Shows lines as they are (only very long ones are shortened).
final class PlainLogFormatter implements AgentLogFormatter {
  const PlainLogFormatter();

  @override
  List<String> format(String line) => [_shorten(line, 2000)];

  @override
  List<String> formatAll(Iterable<String> lines) => [for (final line in lines) ...format(line)];
}

/// Condenses Claude Code's `--output-format stream-json --verbose`: the
/// assistant's text, one line per tool call (`▸ Bash git status`), failed
/// tool results and denied permissions (`  ✗ …`), rate limits and the final
/// result with turns, time, cost and session id. Lines that are not JSON
/// (the launcher's `# kanban-ai:` lines, stderr) pass through; JSON events
/// of other kinds (tool output, hooks, …) are left out.
final class ClaudeStreamJsonFormatter implements AgentLogFormatter {
  String? _cwd;
  final _tools = <String, String>{};

  @override
  List<String> formatAll(Iterable<String> lines) => [for (final line in lines) ...format(line)];

  @override
  List<String> format(String line) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('{')) return [_shorten(line, 2000)];
    final Object? event;
    try {
      event = jsonDecode(trimmed);
    } on FormatException {
      return [_shorten(line, 2000)];
    }
    if (event is! Map) return [_shorten(line, 2000)];
    return switch (event['type']) {
      'system' => _system(event),
      'assistant' => _assistant(event),
      'user' => _user(event),
      'result' => _result(event),
      'rate_limit_event' => _rateLimit(event),
      _ => const [],
    };
  }

  List<String> _system(Map<Object?, Object?> event) {
    switch (event['subtype']) {
      case 'init':
        _cwd = _string(event['cwd']);
        return [
          [
            ['Claude Code', ?_string(event['claude_code_version'])].join(' '),
            ?_string(event['model']),
            if (_string(event['session_id']) case final session?) 'session $session',
          ].join(' · ').replaceFirst('Claude Code', '● Claude Code'),
        ];
      default:
        return const [];
    }
  }

  List<String> _assistant(Map<Object?, Object?> event) {
    final lines = <String>[];
    for (final block in _content(event)) {
      switch (block['type']) {
        case 'text':
          final text = _string(block['text'])?.trimRight() ?? '';
          if (text.isNotEmpty) lines.addAll(text.split('\n').map((l) => _shorten(l, 2000)));
        case 'tool_use':
          final name = _string(block['name']) ?? 'tool';
          if (_string(block['id']) case final id?) _tools[id] = name;
          final summary = _toolSummary(name, block['input']);
          lines.add('▸ $name${summary.isEmpty ? '' : ' $summary'}');
      }
    }
    return lines;
  }

  List<String> _user(Map<Object?, Object?> event) {
    final lines = <String>[];
    for (final block in _content(event)) {
      if (block['type'] != 'tool_result' || block['is_error'] != true) continue;
      final tool = _tools[_string(block['tool_use_id'])] ?? 'tool';
      final text = _resultText(block['content']).trim().split('\n').first;
      lines.add('  ✗ $tool: ${_shorten(text, 200)}');
    }
    return lines;
  }

  List<String> _result(Map<Object?, Object?> event) {
    final parts = <String>[
      if (event['is_error'] == true) 'failed (${_string(event['subtype']) ?? 'error'})' else 'done',
      if (event['num_turns'] case final int turns) '$turns turns',
      if (event['duration_ms'] case final num ms) '${(ms / 1000).toStringAsFixed(1)} s',
      if (event['total_cost_usd'] case final num cost) '\$${cost.toStringAsFixed(2)}',
      if (_string(event['session_id']) case final session?) 'session $session',
    ];
    return [
      '■ ${parts.join(' · ')}',
      if (event['is_error'] == true)
        if (_string(event['result']) case final result? when result.trim().isNotEmpty) '  ${_shorten(result, 500)}',
    ];
  }

  List<String> _rateLimit(Map<Object?, Object?> event) {
    final info = event['rate_limit_info'];
    if (info is! Map) return const [];
    final status = _string(info['status']);
    if (status == null || status == 'allowed') return const [];
    final resets = info['resetsAt'];
    final at = resets is int ? DateTime.fromMillisecondsSinceEpoch(resets * 1000, isUtc: true).toIso8601String() : null;
    return ['! rate limit: $status${at == null ? '' : ' until $at'}'];
  }

  String _toolSummary(String name, Object? input) {
    if (input is! Map) return '';
    String? field(String key) => _string(input[key]);
    final summary = switch (name) {
      'Bash' => field('command')?.split('\n').first,
      'Read' || 'Write' || 'Edit' || 'NotebookEdit' => _relative(field('file_path') ?? field('notebook_path')),
      'Grep' || 'Glob' => [field('pattern'), _relative(field('path'))].nonNulls.join(' in '),
      'TodoWrite' => input['todos'] is List ? '${(input['todos'] as List).length} todos' : null,
      'Task' || 'Agent' => field('description'),
      'WebFetch' => field('url'),
      'WebSearch' => field('query'),
      _ => input.isEmpty ? null : jsonEncode(input),
    };
    return _shorten(summary ?? '', 160);
  }

  String? _relative(String? path) {
    final cwd = _cwd;
    if (path == null || cwd == null) return path;
    final prefix = cwd.endsWith('/') ? cwd : '$cwd/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  static List<Map<Object?, Object?>> _content(Map<Object?, Object?> event) {
    final message = event['message'];
    final content = message is Map ? message['content'] : null;
    return [
      if (content is List)
        for (final block in content)
          if (block is Map) block,
    ];
  }

  static String _resultText(Object? content) => switch (content) {
    final String text => text,
    final List<Object?> blocks => [
      for (final block in blocks)
        if (block is Map && block['text'] is String) block['text']! as String,
    ].join('\n'),
    _ => '',
  };

  static String? _string(Object? value) => value is String ? value : null;
}

/// [text] cut to [max] characters with an ellipsis.
String _shorten(String text, int max) => text.length <= max ? text : '${text.substring(0, max - 1)}…';
