import 'dart:async';

import 'package:backlog_api/backlog_api.dart';

/// Calls [onChange] after the server reported changes, at most once per
/// [delay] — a burst of edits by an agent causes one reload, not ten.
final class DebouncedChanges {
  DebouncedChanges(BacklogApi api, this.onChange, {this.delay = const Duration(milliseconds: 300)}) {
    _subscription = api.changes().listen((_) {
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
