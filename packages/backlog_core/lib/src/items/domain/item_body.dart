import 'discussion.dart';

/// Edits of an item's description — the body above its `## Discussion`
/// section — that leave the discussion as it is.
abstract final class ItemBody {
  static final _fence = RegExp(r'^\s{0,3}(```|~~~)');
  static final _heading = RegExp(r'^(#{1,2})\s+(.*?)\s*#*\s*$');

  /// Whether [name] can head a section of the description: not empty, one
  /// line, not the discussion.
  static bool isSectionName(String name) =>
      name.trim().isNotEmpty && !name.contains('\n') && name.trim().toLowerCase() != 'discussion';

  /// [body] with its description replaced by [text]; the discussion stays.
  static String withDescription(String body, String text) {
    final parts = [text.trim(), Discussion.split(body).rest.trim()].where((part) => part.isNotEmpty);
    return parts.isEmpty ? '' : '${parts.join('\n\n')}\n';
  }

  /// [body] with the content of the description's section headed
  /// `## [section]` (any case) replaced by [text], up to the next heading
  /// of level 1 or 2; a missing section is added at the end of the
  /// description. The discussion stays; it is no section to replace
  /// ([isSectionName]).
  static String withSection(String body, String section, String text) {
    final name = section.trim();
    if (!isSectionName(name)) throw ArgumentError.value(section, 'section', 'is not a section of the description');
    final (:description, :rest) = Discussion.split(body);
    final lines = description.split('\n');
    int? start;
    var end = lines.length;
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final match = _heading.firstMatch(line);
      if (match == null) continue;
      if (start != null) {
        end = i;
        break;
      }
      if (match[1] == '##' && match[2]!.toLowerCase() == name.toLowerCase()) start = i;
    }
    final content = text.trim();
    final String edited;
    if (start == null) {
      final before = description.trimRight();
      edited = '${before.isEmpty ? '' : '$before\n\n'}## $name\n\n$content';
    } else {
      final head = lines.sublist(0, start + 1).join('\n');
      final after = lines.sublist(end).join('\n').trim();
      edited = '$head\n\n$content${after.isEmpty ? '' : '\n\n$after'}';
    }
    return '${edited.trimRight()}\n${rest.trim().isEmpty ? '' : '\n${rest.trim()}\n'}';
  }
}
