import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Where things live inside a backlog folder.
final class BacklogLayout {
  BacklogLayout(String root) : root = p.normalize(p.absolute(root));

  static const configFileName = 'backlog.yaml';

  final String root;

  String get configFile => p.join(root, configFileName);
  String get itemsDir => p.join(root, 'items');

  /// Finished items moved out of [itemsDir] (`backlog archive`); same layout.
  String get archiveDir => p.join(root, 'archive');
  String get viewsDir => p.join(root, 'views');
  String get docsDir => p.join(root, 'docs');

  /// Claim locks; machine-local state, never committed.
  String get locksDir => p.join(root, '.locks');

  String relative(String path) => p.relative(path, from: root);

  /// Finds the backlog for [start]: the folder itself or an ancestor that holds
  /// `backlog.yaml`, or that has a `backlog/` subfolder holding it. The second
  /// form lets agents in sibling worktrees find a shared `../backlog`.
  static String? locate(String start) {
    var dir = p.normalize(p.absolute(start));
    while (true) {
      if (File(p.join(dir, configFileName)).existsSync()) return dir;
      final nested = p.join(dir, 'backlog');
      if (File(p.join(nested, configFileName)).existsSync()) return nested;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }
}

final _random = Random();

/// Writes through a temporary sibling and a rename, so that a concurrent
/// reader sees either the old or the new content, never half a file.
Future<void> writeAtomically(File file, String content) async {
  await file.parent.create(recursive: true);
  final temp = File(p.join(file.parent.path, '.${p.basename(file.path)}.${pid}_${_random.nextInt(1 << 32)}.tmp'));
  await temp.writeAsString(content, flush: true);
  try {
    await temp.rename(file.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}
