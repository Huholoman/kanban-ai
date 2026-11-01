import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What [BacklogCommits.commit] did.
final class BacklogCommit {
  const BacklogCommit({required this.message, required this.paths, this.pushError});

  /// The commit message; its first line names the items and what changed.
  final String message;

  /// The committed paths, relative to the backlog folder.
  final List<String> paths;

  /// Why the push after the commit failed; null when it was not asked for or
  /// went through.
  final String? pushError;

  String get subject => message.split('\n').first;
}

/// Commits the changes in a backlog folder that is a git repository of its
/// own (its top level), as the server does for agents (`git.commit: auto`):
/// they change items through the CLI from their worktrees but never commit
/// the backlog.
///
/// One commit takes everything that changed (claim locks and temp files are
/// left out; `backlog init` also ignores them); its message names the
/// items and what happened to them, e.g. `Backlog: KA-7f3a status review,
/// comment by wt-2; KA-9k2d new`.
final class BacklogCommits {
  BacklogCommits(String root, {this.timeout = const Duration(seconds: 60)}) : root = p.normalize(p.absolute(root));

  final String root;
  final Duration timeout;

  static const _ignored = [':(exclude).locks', ':(exclude,glob)**/*.tmp', ':(exclude,glob)**/*.stale'];

  /// Whether the folder is the top level of a git repository.
  Future<bool> ownsRepository() async {
    if (!await Directory(root).exists()) return false;
    try {
      final top = await _git(['rev-parse', '--show-toplevel']);
      if (top.exitCode != 0) return false;
      final resolved = await Directory(root).resolveSymbolicLinks();
      return p.equals(await Directory('${top.stdout}'.trim()).resolveSymbolicLinks(), resolved);
    } on ProcessException {
      return false;
    }
  }

  /// Commits what changed (and with [push] pushes it); null when nothing
  /// changed or the folder is not a repository of its own. [ids] are the
  /// known item ids, to tell an item's file name from its slug. Fails with
  /// a [StateError] when git refuses the commit.
  Future<BacklogCommit?> commit({Iterable<String> ids = const [], bool push = false}) async {
    if (!await ownsRepository()) return null;
    final status = await _git(['status', '--porcelain=v1', '-z', '--untracked-files=all', '--', '.', ..._ignored]);
    if (status.exitCode != 0) throw StateError('git status failed: ${_first(status.stderr)}');
    final changes = _parseStatus('${status.stdout}');
    if (changes.isEmpty) return null;

    final known = ids.toList()..sort((a, b) => b.length.compareTo(a.length));
    final byItem = <String, List<String>>{};
    final others = <String>[];
    for (final (:code, :path) in changes) {
      final id = _itemOf(path, known);
      if (id == null) {
        others.add(path);
        continue;
      }
      final what = byItem.putIfAbsent(id, () => []);
      for (final change in await _describe(code, path)) {
        if (!what.contains(change)) what.add(change);
      }
    }
    final parts = [for (final MapEntry(key: id, value: what) in byItem.entries) '$id ${what.join(', ')}', ...others];
    final subject = parts.length > 6
        ? 'Backlog: ${parts.take(5).join('; ')}; and ${parts.length - 5} more'
        : 'Backlog: ${parts.join('; ')}';
    final paths = [for (final change in changes) change.path];
    final message = '$subject\n\n${paths.map((path) => '- $path').join('\n')}\n';

    final added = await _git(['add', '-A', '--', ...paths.map((path) => ':(literal)$path')]);
    if (added.exitCode != 0) throw StateError('git add failed: ${_first(added.stderr)}');
    final committed = await _git(['commit', '--quiet', '--no-verify', '-m', message]);
    if (committed.exitCode != 0) {
      throw StateError('git commit failed: ${_first(committed.stderr).ifEmpty(_first(committed.stdout))}');
    }
    String? pushError;
    if (push) {
      final pushed = await _git(['push', '--quiet']);
      if (pushed.exitCode != 0) pushError = _first(pushed.stderr).ifEmpty('git push failed');
    }
    return BacklogCommit(message: message, paths: paths, pushError: pushError);
  }

  /// `XY path` entries of `git status -z`; a rename's source is skipped.
  static List<({String code, String path})> _parseStatus(String output) {
    final entries = <({String code, String path})>[];
    final fields = output.split('\x00');
    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      if (field.length < 4) continue;
      final code = field.substring(0, 2);
      entries.add((code: code, path: field.substring(3)));
      if (code.contains('R') || code.contains('C')) i++; // the old name follows
    }
    return entries;
  }

  /// The item whose file [path] is (`items/<id>-<slug>.md`,
  /// `items/<id>/index.md`, …), by the longest known id it starts with,
  /// else the name up to the second dash.
  static String? _itemOf(String path, List<String> known) {
    final parts = p.posix.split(path);
    if (parts.length < 2 || parts.first != 'items') return null;
    final name = parts[1];
    for (final id in known) {
      if (name == id || name == '$id.md' || name.startsWith('$id-') || name.startsWith('$id.')) return id;
    }
    final stem = name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
    final dashes = stem.split('-');
    return dashes.length >= 2 ? '${dashes[0]}-${dashes[1]}' : stem;
  }

  /// What happened to [path]: `new`, `deleted`, or from its diff the new
  /// `status …`, `priority …` and `comment by …`, else `edited`.
  Future<List<String>> _describe(String code, String path) async {
    if (code == '??' || code.contains('A')) return const ['new'];
    if (code.contains('D')) return const ['deleted'];
    final diff = await _git(['diff', '--no-ext-diff', '--unified=0', 'HEAD', '--', path]);
    final what = <String>[];
    for (final line in '${diff.stdout}'.split('\n')) {
      if (!line.startsWith('+') || line.startsWith('+++')) continue;
      final text = line.substring(1);
      if (text.startsWith('status:') || text.startsWith('priority:')) {
        what.add(text.replaceFirst(':', '').trim());
      } else if (text.startsWith('### ') && text.contains(' · ')) {
        final author = text.substring(4).split(' · ').first.trim();
        final kind = text.contains('· review')
            ? 'review'
            : text.endsWith('· note')
            ? 'note'
            : 'comment';
        what.add('$kind by $author');
      }
    }
    return what.isEmpty ? const ['edited'] : what;
  }

  Future<ProcessResult> _git(List<String> arguments) => Process.run(
    'git',
    arguments,
    workingDirectory: root,
    environment: const {'GIT_EDITOR': 'true', 'GIT_TERMINAL_PROMPT': '0'},
  ).timeout(timeout);

  static String _first(Object? text) => '$text'.trim().split('\n').first;
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
