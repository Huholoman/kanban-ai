import 'dart:async';
import 'dart:io';

import '../domain/review_state.dart';

/// [BranchHeads] read with `git for-each-ref` in the first of [candidates]
/// that is a folder (the primary clone, the dispatcher's worktrees — all
/// worktrees of a clone share its branches — or the backlog folder, which
/// may live inside the code repository). Calls made while one runs share
/// its result; nothing else is cached, so new commits count at once.
final class GitBranchHeads implements BranchHeads {
  GitBranchHeads(this.candidates, {this.timeout = const Duration(seconds: 10)});

  /// Folders to ask, in order.
  final List<String> candidates;
  final Duration timeout;
  Future<Map<String, BranchHead>>? _running;

  @override
  Future<Map<String, BranchHead>> heads() => _running ??= _read().whenComplete(() => _running = null);

  Future<Map<String, BranchHead>> _read() async {
    for (final folder in candidates) {
      if (!await Directory(folder).exists()) continue;
      try {
        final result = await Process.run('git', [
          'for-each-ref',
          '--format=%(refname)%09%(objectname)%09%(committerdate:unix)',
          'refs/heads/',
        ], workingDirectory: folder).timeout(timeout);
        if (result.exitCode != 0) continue;
        const prefix = 'refs/heads/';
        return {
          for (final line in '${result.stdout}'.split('\n'))
            if (line.split('\t') case [final ref, final commit, final seconds] when ref.startsWith(prefix))
              ref.substring(prefix.length): BranchHead(
                commit: commit.toLowerCase(),
                committedAt: DateTime.fromMillisecondsSinceEpoch((int.tryParse(seconds) ?? 0) * 1000, isUtc: true),
              ),
        };
      } on ProcessException {
        return const {};
      } on TimeoutException {
        return const {};
      }
    }
    return const {};
  }
}
