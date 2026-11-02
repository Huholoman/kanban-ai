import '../../shared/errors.dart';

/// A file attached to an item (a screenshot, a log, a pasted text), stored
/// next to the item's file.
final class Attachment {
  const Attachment({required this.name, required this.size, this.modified});

  /// The file name, unique within the item (see [checkName]).
  final String name;

  /// Size in bytes.
  final int size;

  /// When the file was last written, when the storage knows it.
  final DateTime? modified;

  /// The longest name accepted, in characters.
  static const maxNameLength = 200;

  /// [name] trimmed, when it can name an attachment: one file name (no
  /// folders), not hidden, not the item's own `index.md`, without control
  /// characters and at most [maxNameLength] long. Otherwise an
  /// [InvalidInputException].
  static String checkName(String name) {
    final trimmed = name.trim();
    final problem = switch (trimmed) {
      '' => 'is empty',
      _ when trimmed.length > maxNameLength => 'is longer than $maxNameLength characters',
      _ when trimmed.contains('/') || trimmed.contains(r'\') => 'contains a slash',
      _ when trimmed.startsWith('.') => 'starts with a dot',
      _ when trimmed.toLowerCase() == 'index.md' => 'is the item file',
      _ when trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) => 'contains control characters',
      _ => null,
    };
    if (problem != null) throw InvalidInputException('The attachment name "$trimmed" $problem.');
    return trimmed;
  }

  /// [name] when none of [taken] has it, else the first free of `name-2.ext`,
  /// `name-3.ext`, … (compared without case, as some file systems do).
  static String freeName(String name, Iterable<String> taken) {
    final used = {for (final other in taken) other.toLowerCase()};
    if (!used.contains(name.toLowerCase())) return name;
    final dot = name.lastIndexOf('.');
    final (stem, extension) = dot > 0 ? (name.substring(0, dot), name.substring(dot)) : (name, '');
    for (var n = 2; ; n++) {
      final candidate = '$stem-$n$extension';
      if (!used.contains(candidate.toLowerCase())) return candidate;
    }
  }
}
