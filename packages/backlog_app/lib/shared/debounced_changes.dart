import 'dart:async';

import 'package:backlog_api/backlog_api.dart';

/// Calls [onChange] after the server reported changes, at most once per
/// [delay] — a burst of edits by an agent causes one reload, not ten. Only
/// file changes count unless [dispatch] is set: then changes of the
/// dispatcher's plan count too.
final class DebouncedChanges {
  DebouncedChanges(
    BacklogApi api,
    this.onChange, {
    this.delay = const Duration(milliseconds: 300),
    bool dispatch = false,
  }) {
    _subscription = api.changes().listen((event) {
      if (event.isDispatch && !dispatch) return;
      _timer?.cancel();
      _timer = Timer(delay, onChange);
    });
  }

  final void Function() onChange;
  final Duration delay;
  late final StreamSubscription<BacklogChangeEvent> _subscription;
  Timer? _timer;

  Future<void> cancel() async {
    _timer?.cancel();
    await _subscription.cancel();
  }
}
