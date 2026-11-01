import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';

/// Parses a `--where` condition:
/// `status=todo,review`, `labels!=ui`, `title~login` (contains, ignoring
/// case), `milestone?` (has a value), `!milestone?` (has none),
/// `updated<7d` (at most 7 days ago), `created>30d` (more than 30 days ago).
Filter parseWhere(String expression) {
  final text = expression.trim();
  final exists = RegExp(r'^(!?)([A-Za-z_][A-Za-z0-9_-]*)\?$').firstMatch(text);
  if (exists != null) {
    return FieldExists(exists.group(2)!, exists: exists.group(1)!.isEmpty);
  }
  final age = RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*?)\s*([<>])\s*(\S+)$').firstMatch(text);
  if (age != null) {
    final duration =
        FieldAge.parseAge(age.group(3)!) ??
        (throw UsageException('Cannot parse the age in --where "$expression".', 'Use e.g. updated<24h, created>2w.'));
    return FieldAge(age.group(1)!, duration, older: age.group(2) == '>');
  }
  final contains = RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*?)\s*~(.+)$').firstMatch(text);
  if (contains != null) return FieldContains(contains.group(1)!, contains.group(2)!.trim());
  final match = RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*?)\s*(!=|=)(.*)$').firstMatch(text);
  if (match == null) {
    throw UsageException(
      'Cannot parse --where "$expression".',
      'Use field=a,b, field!=a, field~text, field?, !field?, field<7d or field>30d.',
    );
  }
  final values = match.group(3)!.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty);
  final filter = FieldIn(match.group(1)!, values);
  return match.group(2) == '!=' ? Not(filter) : filter;
}

Filter combineWhere(Iterable<String> expressions, [Iterable<Filter> extra = const []]) =>
    AllOf([...expressions.map(parseWhere), ...extra]);
