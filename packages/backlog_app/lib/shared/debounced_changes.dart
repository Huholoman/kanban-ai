import 'dart:async';

import 'package:backlog_api/backlog_api.dart';

/// Calls [onChange] after the server reported changes, at most once per
/// [delay] — a burst of edits by an agent causes one reload, not ten. Only
/// changes of the [watched] parts count; [onChange] gets the watched parts
/// that changed since its last call, so that it reloads only those.
final class DebouncedChanges {
  DebouncedChanges(
    BacklogApi api,
    this.onChange, {
    this.delay = const Duration(milliseconds: 300),
    this.watched = const {BacklogPart.workflow, BacklogPart.items, BacklogPart.views},
  }) {
    _subscription = api.changes().listen((event) {
      final parts = event.parts.intersection(watched);
      if (parts.isEmpty) return;
      _pending.addAll(parts);
      _timer?.cancel();
      _timer = Timer(delay, () {
        final changed = {..._pending};
        _pending.clear();
        onChange(changed);
      });
    });
  }

  final void Function(Set<BacklogPart> changed) onChange;
  final Duration delay;
  final Set<BacklogPart> watched;
  final _pending = <BacklogPart>{};
  late final StreamSubscription<BacklogChangeEvent> _subscription;
  Timer? _timer;

  Future<void> cancel() async {
    _timer?.cancel();
    await _subscription.cancel();
  }
}
