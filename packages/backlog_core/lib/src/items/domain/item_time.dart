/// Values of `created` and `updated` in item files: a UTC instant
/// (`2026-10-31T20:27:12Z`, what the tools write) or, in older files, a
/// calendar day (`2026-10-31`), read as it is and kept until the item changes.
abstract final class ItemTime {
  static final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _zone = RegExp(r'(Z|[+-]\d{2}(:?\d{2})?)$', caseSensitive: false);

  /// [time] in UTC to the second: `2026-10-31T20:27:12Z`.
  static String format(DateTime time) {
    final utc = time.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
        'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }

  /// The instant [value] names, in UTC; a calendar day is its midnight UTC and
  /// a time without a zone counts as UTC. Null when [value] is not a time.
  static DateTime? parse(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (_day.hasMatch(text)) {
      final day = DateTime.tryParse(text);
      return day == null ? null : DateTime.utc(day.year, day.month, day.day);
    }
    if (!text.contains('T') && !text.contains(' ')) return null;
    return DateTime.tryParse(_zone.hasMatch(text) ? text : '${text}Z')?.toUtc();
  }

  /// The UTC calendar day of [value] (`2026-10-31`); null when it is not a time.
  static String? day(String? value) {
    final time = parse(value);
    return time == null ? null : format(time).substring(0, 10);
  }

  /// True when [value] names an instant, not only a day.
  static bool hasTime(String? value) => value != null && !_day.hasMatch(value.trim()) && parse(value) != null;

  /// Orders [a] and [b] chronologically; values that are not times come last
  /// (in text order among themselves).
  static int compare(String? a, String? b) {
    final left = parse(a);
    final right = parse(b);
    if (left != null && right != null) {
      final byTime = left.compareTo(right);
      return byTime != 0 ? byTime : (a ?? '').compareTo(b ?? '');
    }
    if (left != null || right != null) return left != null ? -1 : 1;
    if (a == null || b == null) return a == b ? 0 : (a == null ? 1 : -1);
    return a.compareTo(b);
  }
}
