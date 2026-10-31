import 'dart:async';
import 'dart:io';

import '../domain/branch_changes.dart';
import '../domain/review_state.dart';

/// [BranchChanges] read with `git diff --name-only <base>...<branch>` in the
/// first of [candidates] that is a repository (the same folders as
/// `GitBranchHeads`). The diff is taken between the head commits, so a
/// result stays valid as long as neither head moves: it is kept until a call
/// no longer asks for that pair.
final class GitBranchChanges implements BranchChanges {
  GitBranchChanges(this.candidates, {this.base = 'main', this.timeout = const Duration(seconds: 10)});

  /// Folders to ask, in order.
  final List<String> candidates;

  /// The branch the work branches fork from (`dispatcher.base`).
  final String base;
  final Duration timeout;
  var _cache = <String, List<String>>{};

  @override
  Future<Map<String, List<String>>> changedFiles(Map<String, BranchHead> heads, Iterable<String> branches) async {
    final baseHead = heads[base];
    if (baseHead == null) return const {};
    final cache = <String, List<String>>{};
    final result = <String, List<String>>{};
    for (final branch in branches) {
      final head = heads[branch];
      if (branch == base || head == null) continue;
      final key = '${baseHead.commit}...${head.commit}';
      final files = cache[key] ?? _cache[key] ?? await _diff(key);
      if (files == null) continue;
      cache[key] = result[branch] = files;
    }
    _cache = cache;
    return result;
  }

  /// Changed paths for the commit range [range], or null when no folder can
  /// tell.
  Future<List<String>?> _diff(String range) async {
    for (final folder in candidates) {
      if (!await Directory(folder).exists()) continue;
      try {
        final arguments = ['diff', '--name-only', '--no-renames', '-z', range, '--'];
        final result = await Process.run('git', arguments, workingDirectory: folder).timeout(timeout);
        if (result.exitCode != 0) continue;
        return List.unmodifiable([
          for (final path in '${result.stdout}'.split('\x00'))
            if (path.isNotEmpty) path,
        ]);
      } on ProcessException {
        return null;
      } on TimeoutException {
        return null;
      }
    }
    return null;
  }
}
