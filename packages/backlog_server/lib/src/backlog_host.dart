import 'package:backlog_core/backlog_core.dart';

/// Keeps the opened [Backlog] of one folder and reopens it after
/// `backlog.yaml` changes, so that edits of the workflow apply without a
/// restart.
final class BacklogHost {
  BacklogHost(this.root, {this.clock = const SystemClock()});

  final String root;
  final Clock clock;
  Future<Backlog>? _current;

  Future<Backlog> get backlog => _current ??= _open();

  Future<Backlog> _open() async {
    try {
      return await Backlog.open(root, clock: clock);
    } catch (_) {
      // A broken configuration must not stay cached once it is fixed.
      _current = null;
      rethrow;
    }
  }

  /// Forgets the opened backlog; the next access reads the configuration again.
  void reload() => _current = null;
}
