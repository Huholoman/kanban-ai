import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../domain/item_history.dart';

/// [ItemRevisions] from the git repository the backlog lives in: the commits
/// that touched a file of the item — any name starting with its id, since a
/// new title renames the file — read with one `git cat-file --batch`. At
/// most [limit] commits, the newest ones.
final class GitItemRevisions implements ItemRevisions {
  const GitItemRevisions({this.limit = 200, this.timeout = const Duration(seconds: 20)});

  final int limit;
  final Duration timeout;

  @override
  Future<List<ItemRevision>> of(String path, ItemId id, Item Function(String text) decode) async {
    // `items/<id>-<slug>.md` or `items/<id>-<slug>/index.md`.
    final folder = p.basename(path) == 'index.md' ? p.dirname(p.dirname(path)) : p.dirname(path);
    try {
      final top = await Process.run('git', ['rev-parse', '--show-toplevel'], workingDirectory: folder).timeout(timeout);
      if (top.exitCode != 0) return const [];
      final log = await Process.run('git', [
        'log',
        '-n',
        '$limit',
        '--format=%x1e%H%x1f%an%x1f%aI',
        '--name-only',
        '--',
        for (final name in ['$id.md', '$id-*.md', '$id/index.md', '$id-*/index.md']) ':(glob)$name',
      ], workingDirectory: folder).timeout(timeout);
      if (log.exitCode != 0) return const [];
      final commits = <({String commit, String author, DateTime at, List<String> paths})>[];
      for (final record in '${log.stdout}'.split('\x1e')) {
        final lines = record.trim().split('\n');
        if (lines.length < 2) continue;
        final head = lines.first.split('\x1f');
        final at = head.length == 3 ? DateTime.tryParse(head[2]) : null;
        final paths = [
          for (final line in lines.skip(1))
            if (line.trim().isNotEmpty) line.trim(),
        ];
        if (at == null || paths.isEmpty) continue;
        commits.add((commit: head[0], author: head[1], at: at.toUtc(), paths: paths));
      }
      if (commits.isEmpty) return const [];

      // A commit may list the old name of a renamed file too; it is missing there.
      final texts = await _contents('${top.stdout}'.trim(), [
        for (final commit in commits)
          for (final file in commit.paths) '${commit.commit}:$file',
      ]);
      final revisions = <ItemRevision>[];
      var index = 0;
      for (final commit in commits) {
        Item? found;
        for (final _ in commit.paths) {
          final text = texts[index++];
          if (found != null || text == null) continue;
          try {
            final item = decode(text);
            if (item.id == id) found = item;
          } on FormatException {
            continue;
          }
        }
        if (found != null) {
          revisions.add(ItemRevision(item: found, at: commit.at, commit: commit.commit, author: commit.author));
        }
      }
      return revisions.reversed.toList();
    } on ProcessException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  /// The contents of the blobs [specs] (`<commit>:<path>`), null for missing ones.
  Future<List<String?>> _contents(String repo, List<String> specs) async {
    final process = await Process.start('git', ['cat-file', '--batch'], workingDirectory: repo);
    process.stdin.write(specs.map((spec) => '$spec\n').join());
    final closing = process.stdin.close();
    final bytes = <int>[];
    final reading = process.stdout.forEach(bytes.addAll);
    unawaited(process.stderr.drain<void>());
    await Future.wait([closing, reading]).timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return const [];
      },
    );
    await process.exitCode;
    final results = <String?>[];
    var offset = 0;
    for (var index = 0; index < specs.length; index++) {
      final newline = bytes.indexOf(10, offset);
      if (newline < 0) break;
      final header = utf8.decode(bytes.sublist(offset, newline)).split(' ');
      offset = newline + 1;
      if (header.length < 3 || header[1] != 'blob') {
        results.add(null);
        continue;
      }
      final size = int.parse(header[2]);
      results.add(utf8.decode(bytes.sublist(offset, offset + size), allowMalformed: true));
      offset += size + 1;
    }
    while (results.length < specs.length) {
      results.add(null);
    }
    return results;
  }
}
