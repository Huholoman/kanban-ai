import 'package:flutter/material.dart';

String _two(int value) => value.toString().padLeft(2, '0');

/// [time] in local time, to the second: `31.10.2026 21:27:12`.
String exactTime(DateTime time) {
  final local = time.toLocal();
  return '${local.day}.${local.month}.${local.year} '
      '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

/// How long ago [time] was for recent times (`just now`, `5 min ago`,
/// `3 h ago`, `2 days ago`), else the local date and time (`31.10. 21:27`,
/// with the year when it is not this one).
String relativeTime(DateTime time, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final local = time.toLocal();
  final ago = current.difference(local);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
  if (ago.inHours < 24) return '${ago.inHours} h ago';
  if (ago.inDays < 7) return ago.inDays == 1 ? 'yesterday' : '${ago.inDays} days ago';
  final day = local.year == current.year ? '${local.day}.${local.month}.' : '${local.day}.${local.month}.${local.year}';
  return '$day ${_two(local.hour)}:${_two(local.minute)}';
}

/// A moment shown relative to now ([relativeTime]), the exact local time
/// ([exactTime]) in its tooltip.
class TimeText extends StatelessWidget {
  const TimeText(this.time, {super.key, this.prefix = '', this.style, this.now});

  final DateTime time;

  /// Text before the time, e.g. `created `.
  final String prefix;
  final TextStyle? style;

  /// The current time; [DateTime.now] when null (tests pass a fixed one).
  final DateTime? now;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: exactTime(time),
    child: Text('$prefix${relativeTime(time, now: now)}', style: style),
  );
}
