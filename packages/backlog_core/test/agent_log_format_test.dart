import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeStreamJsonFormatter', () {
    test('condenses a real stream-json log into readable lines', () {
      final raw = _fixture('claude-stream-json.log').readAsLinesSync();
      final lines = AgentLogFormatter.forOutput(AgentOutput.claudeStreamJson).formatAll(raw);

      expect(lines.first, startsWith('# kanban-ai: claude for G-rejh'), reason: 'launcher lines pass through');
      expect(lines, contains('● Claude Code 2.1.312 · claude-opus-5-5 · session 5820797a-b7ed-4499-87f8-920f6c9539b9'));
      expect(lines, contains('▸ Bash cat greet.sh; ./greet.sh Alice'));
      expect(lines, contains(startsWith('  ✗ Bash: Permission for this tool use was denied.')));
      expect(lines, containsAllInOrder(['▸ Read greet.sh', '▸ Read README.md', '▸ Edit README.md']));
      expect(lines, contains('Ze zdrojového kódu je vidět, že `./greet.sh Alice` vypíše `Hello, Alice!`.'));
      expect(lines, contains('▸ Bash backlog set G-rejh status=review && backlog lint'));
      expect(lines, contains('■ done · 10 turns · 20.8 s · \$0.23 · session 5820797a-b7ed-4499-87f8-920f6c9539b9'));
      expect(lines.last, contains('claude --resume 5820797a'));
      expect(lines.where((l) => l.startsWith('{')), isEmpty, reason: 'no raw JSON events are left');
      expect(lines.every((l) => l.length <= 2000), isTrue);
    });

    test('reports failed results, rate limits and keeps unparsable lines', () {
      final formatter = ClaudeStreamJsonFormatter();
      expect(
        formatter.format(
          jsonEncode({
            'type': 'result',
            'subtype': 'error_max_turns',
            'is_error': true,
            'num_turns': 3,
            'result': 'Reached the limit',
          }),
        ),
        ['■ failed (error_max_turns) · 3 turns', '  Reached the limit'],
      );
      expect(
        formatter.format(
          jsonEncode({
            'type': 'rate_limit_event',
            'rate_limit_info': {'status': 'rejected', 'resetsAt': 0},
          }),
        ),
        ['! rate limit: rejected until 1970-01-01T00:00:00.000Z'],
      );
      expect(
        formatter.format(
          jsonEncode({
            'type': 'rate_limit_event',
            'rate_limit_info': {'status': 'allowed'},
          }),
        ),
        isEmpty,
      );
      expect(formatter.format('{"type": "assistant", broken'), ['{"type": "assistant", broken']);
      expect(formatter.format(jsonEncode({'type': 'stream_event'})), isEmpty);
    });
  });

  test('other outputs are shown as they are', () {
    expect(AgentLogFormatter.forOutput(AgentOutput.jsonLines).format('{"a": 1}'), ['{"a": 1}']);
    expect(AgentLogFormatter.forOutput(AgentOutput.text).formatAll(['a', 'b']), ['a', 'b']);
  });
}

/// A file of `test/fixtures`, whether the tests run in the package or in the
/// workspace root.
File _fixture(String name) => [
  File('test/fixtures/$name'),
  File('packages/backlog_core/test/fixtures/$name'),
].firstWhere((file) => file.existsSync());
