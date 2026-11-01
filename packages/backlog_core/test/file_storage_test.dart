import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

import 'storage_contract.dart';

void main() {
  for (final cacheItems in [false, true]) {
    storageContract(cacheItems ? 'FileBacklogStorage (item cache)' : 'FileBacklogStorage', () async {
      final dir = await Directory.systemTemp.createTemp('backlog_storage_');
      addTearDown(() => dir.delete(recursive: true));
      await Backlog.init(dir.path);
      return () => FileBacklogStorage(dir.path, cacheItems: cacheItems);
    }, files: true);
  }
}
