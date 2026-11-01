import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';

import '../backlog_host.dart';

/// Commits a hosted backlog by itself (`git.commit: auto`, the default):
/// agents change items through the CLI from their worktrees and never commit
/// the backlog's own repository, so the server does — [quiet] after the last
/// change (at the latest [maxWait] after the first one not yet committed),
/// and soon after an agent's or action's run has ended ([runEnded]). Only a
/// backlog folder that is the top level of its git repository is committed
/// ([BacklogCommits]); with `git.push` each commit is pushed.
final class BacklogAutoCommit {
  BacklogAutoCommit(
    this.host, {
    this.quiet = const Duration(seconds: 30),
    this.maxWait = const Duration(minutes: 5),
    this.afterRun = const Duration(seconds: 2),
    required this.log,
  }) : _commits = BacklogCommits(host.root);

  final BacklogHost host;
  final Duration quiet;
  final Duration maxWait;
  final Duration afterRun;
  final void Function(String message) log;
  final BacklogCommits _commits;
  Timer? _timer;
  DateTime? _since;
  Future<void> _running = Future.value();
  bool _closed = false;

  /// Files of the backlog changed: commit once it is quiet.
  void changed(BacklogChangeEvent event) {
    if (!event.paths.any(_committed)) return;
    final now = DateTime.now();
    _since ??= now;
    final latest = _since!.add(maxWait).difference(now);
    _schedule(latest < quiet ? latest : quiet);
  }

  /// A run has ended: what its agent changed goes in now.
  void runEnded() => _schedule(afterRun);

  /// Commits what changed now (after a commit already running).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _since = null;
    return _running = _running.then((_) => _commit());
  }

  /// Commits what waits for the quiet period, then stops.
  Future<void> close() async {
    if (_timer != null) await flush();
    _closed = true;
    await _running;
  }

  void _schedule(Duration delay) {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () => unawaited(flush()));
  }

  static bool _committed(String path) => !path.startsWith('.locks/') && path != '.locks';

  Future<void> _commit() async {
    if (_closed) return;
    try {
      final backlog = await host.backlog;
      final git = backlog.workflow.git;
      if (git.commit == BacklogCommitMode.off) return;
      final ids = (await backlog.planning.snapshot()).ids.map((id) => id.value);
      final commit = await _commits.commit(ids: ids, push: git.push);
      if (commit == null) return;
      log('Backlog: committed ${commit.paths.length} file(s): ${commit.subject}');
      if (commit.pushError case final error?) log('Backlog: push failed: $error');
    } on Object catch (error) {
      log('Backlog: commit failed: $error');
    }
  }
}
