import 'dart:async';

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

/// One shared tick for every [TimeText]: it notifies its listeners every
/// [interval] while it has any (one timer for the whole app, none while no
/// time is shown), and tells the current time ([now]).
class TimeTicker extends ChangeNotifier {
  TimeTicker({DateTime Function()? clock, this.interval = const Duration(minutes: 1)}) : _clock = clock ?? DateTime.now;

  /// The ticker [TimeText] uses; tests replace it to control the time.
  static TimeTicker instance = TimeTicker();

  final DateTime Function() _clock;
  final Duration interval;
  Timer? _timer;

  DateTime get now => _clock();

  /// Its timer runs (some [TimeText] is shown).
  bool get ticking => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(interval, (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A moment shown relative to now ([relativeTime]), the exact local time
/// ([exactTime]) in its tooltip. Without a fixed [now] it follows
/// [TimeTicker.instance], so "5 min ago" keeps counting.
class TimeText extends StatelessWidget {
  const TimeText(this.time, {super.key, this.prefix = '', this.style, this.now});

  final DateTime time;

  /// Text before the time, e.g. `created `.
  final String prefix;
  final TextStyle? style;

  /// A fixed current time; null follows [TimeTicker.instance].
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    Widget text(DateTime now) => Text('$prefix${relativeTime(time, now: now)}', style: style);
    final fixed = now;
    return Tooltip(
      message: exactTime(time),
      child: fixed != null
          ? text(fixed)
          : ListenableBuilder(listenable: TimeTicker.instance, builder: (context, _) => text(TimeTicker.instance.now)),
    );
  }
}
