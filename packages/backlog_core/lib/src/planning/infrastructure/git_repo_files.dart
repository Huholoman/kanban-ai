import 'dart:async';
import 'dart:io';

import '../domain/touches_estimate.dart';

/// [RepoFiles] read with `git ls-tree` at the base branch (else `HEAD`) in
/// the first of [candidates] that is a repository: the files as they are on
/// the branch new work starts from, whatever is checked out.
final class GitRepoFiles implements RepoFiles {
  GitRepoFiles(this.candidates, {this.base = 'main', this.timeout = const Duration(seconds: 10)});

  /// Folders to ask, in order.
  final List<String> candidates;

  /// The branch whose files count (`dispatcher.base`).
  final String base;
  final Duration timeout;

  @override
  Future<List<String>> list() async {
    for (final folder in candidates) {
      if (!await Directory(folder).exists()) continue;
      for (final ref in [base, 'HEAD']) {
        try {
          final arguments = ['ls-tree', '-r', '--name-only', '-z', ref];
          final result = await Process.run('git', arguments, workingDirectory: folder).timeout(timeout);
          if (result.exitCode != 0) continue;
          return List.unmodifiable([
            for (final path in '${result.stdout}'.split('\x00'))
              if (path.isNotEmpty) path,
          ]);
        } on ProcessException {
          return const [];
        } on TimeoutException {
          return const [];
        }
      }
    }
    return const [];
  }
}
