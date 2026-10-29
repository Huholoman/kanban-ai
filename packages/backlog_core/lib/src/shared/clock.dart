/// Source of the current time, injected so that use cases stay testable.
abstract interface class Clock {
  DateTime now();
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// A clock that only moves when told to; meant for tests and simulations.
final class FixedClock implements Clock {
  FixedClock(this.current);

  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration duration) => current = current.add(duration);
}

/// Formats [time] as an ISO calendar day (`2026-10-29`), the format used for
/// `created` and `updated` in item files.
String formatDay(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)}';
}
