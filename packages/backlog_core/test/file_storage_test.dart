import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'storage_contract.dart';

void main() {
  for (final (name, cacheItems, persistent) in [
    ('FileBacklogStorage', false, false),
    ('FileBacklogStorage (item cache)', true, false),
    ('FileBacklogStorage (persistent item cache)', false, true),
    ('FileBacklogStorage (both item caches)', true, true),
  ]) {
    storageContract(name, () async {
      final dir = await Directory.systemTemp.createTemp('backlog_storage_');
      addTearDown(() => dir.delete(recursive: true));
      await Backlog.init(dir.path);
      if (persistent) {
        await File(p.join(dir.path, 'backlog.yaml')).writeAsString('cache:\n  items: true\n', mode: FileMode.append);
      }
      return () => FileBacklogStorage(dir.path, cacheItems: cacheItems);
    }, files: true);
  }
}
