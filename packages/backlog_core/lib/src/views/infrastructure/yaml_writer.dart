import 'dart:convert';

/// Writes JSON-like data (maps, lists, strings, numbers, booleans) as
/// readable block YAML: nested maps indented, lists of scalars in flow style.
/// Strings that YAML could misread are written as JSON strings, which are
/// valid double-quoted YAML.
String toYaml(Map<String, Object?> data) {
  final out = StringBuffer();
  _map(data, 0, out);
  return out.toString();
}

void _map(Map<String, Object?> map, int indent, StringBuffer out) {
  final pad = ' ' * indent;
  for (final MapEntry(:key, :value) in map.entries) {
    if (value == null) continue;
    out.write('$pad${_scalar(key)}:');
    _value(value, indent, out);
  }
}

void _value(Object value, int indent, StringBuffer out) {
  switch (value) {
    case final Map<String, Object?> map when map.isNotEmpty:
      out.writeln();
      _map(map, indent + 2, out);
    case final List<Object?> list when list.isNotEmpty && list.every((v) => v is Map):
      out.writeln();
      for (final element in list.cast<Map<String, Object?>>()) {
        // "- " then the first key on the same line, the rest aligned below.
        final nested = StringBuffer();
        _map(element, indent + 4, nested);
        out.writeln('${' ' * (indent + 2)}- ${nested.toString().trim()}');
      }
    case final List<Object?> list:
      out.writeln(' [${list.map((v) => _scalar(v)).join(', ')}]');
    case final Map<Object?, Object?> _:
      out.writeln(' {}');
    default:
      out.writeln(' ${_scalar(value)}');
  }
}

String _scalar(Object? value) {
  if (value is bool || value is num) return '$value';
  final text = '$value';
  final plain =
      RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_ ./-]*$').hasMatch(text) &&
      !text.endsWith(' ') &&
      !const {'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'}.contains(text.toLowerCase()) &&
      num.tryParse(text) == null;
  return plain ? text : jsonEncode(text);
}
