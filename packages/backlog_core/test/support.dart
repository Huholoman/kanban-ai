import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

/// Hands out `T-0001`, `T-0002`, … so that tests can name items.
final class SequentialIds implements IdGenerator {
  int _next = 1;

  @override
  ItemId next() => ItemId('T-${(_next++).toString().padLeft(4, '0')}');
}

/// A fresh backlog in a temporary folder, deleted after the test.
Future<(Backlog, FixedClock)> tempBacklog({String? config}) async {
  final dir = await Directory.systemTemp.createTemp('backlog_test_');
  addTearDown(() => dir.delete(recursive: true));
  await Backlog.init(dir.path);
  if (config != null) await File('${dir.path}/backlog.yaml').writeAsString(config);
  final clock = FixedClock(DateTime.utc(2026, 10, 29, 12));
  return (await Backlog.open(dir.path, clock: clock, ids: SequentialIds()), clock);
}

Item item(
  String id, {
  String status = 'todo',
  String priority = 'p2',
  String type = 'task',
  String? parent,
  List<String> dependsOn = const [],
  List<String> labels = const [],
  String? milestone,
  String? created,
  String body = '',
}) => Item(
  id: ItemId(id),
  title: 'Item $id',
  type: type,
  status: status,
  priority: priority,
  parent: parent == null ? null : ItemId(parent),
  dependsOn: dependsOn.map(ItemId.new).toList(),
  labels: labels,
  milestone: milestone,
  created: created,
  body: body,
);

BacklogSnapshot snapshotOf(List<Item> items, {List<Claim> claims = const [], DateTime? now}) => BacklogSnapshot.build(
  items: items,
  workflow: Workflow.standard(),
  claims: claims,
  now: now ?? DateTime.utc(2026, 10, 29, 12),
);
