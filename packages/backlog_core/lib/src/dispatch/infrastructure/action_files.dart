import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../domain/action_run.dart';

/// [ActionState] as `actions/<project>/state.json` in the state folder
/// (`$STATE`, see `ProcessAgentLauncher.defaultStateDir`). A broken file
/// counts as no state: statuses are taken anew and nothing is triggered.
final class FileActionStateStore implements ActionStateStore {
  FileActionStateStore({required this.stateDir, required this.project});

  final String stateDir;
  final String project;

  String get file => p.join(stateDir, 'actions', project, 'state.json');

  @override
  Future<ActionState> load() async {
    try {
      return ActionState.fromJson((jsonDecode(await File(file).readAsString()) as Map).cast<String, Object?>());
    } on Object {
      return const ActionState();
    }
  }

  @override
  Future<void> save(ActionState state) async {
    final target = File(file);
    await target.parent.create(recursive: true);
    final temp = File('$file.tmp');
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n');
    await temp.rename(target.path);
  }
}

/// Requests as `.locks/actions/<time>-<random>.json` in the backlog folder:
/// machine-local like claims, never committed, and seen by the server's
/// watcher, which then runs the dispatcher.
final class FileActionRequests implements ActionRequests {
  FileActionRequests(this._layout);

  final BacklogLayout _layout;
  final _random = Random();

  String get folder => p.join(_layout.locksDir, 'actions');

  @override
  Future<void> add(ActionRequest request) async {
    final stamp = request.at.toUtc().microsecondsSinceEpoch.toString().padLeft(17, '0');
    final name = '$stamp-${_random.nextInt(1 << 32).toRadixString(36)}.json';
    await writeAtomically(File(p.join(folder, name)), '${jsonEncode(request.toJson())}\n');
  }

  @override
  Future<List<ActionRequest>> take() async {
    final dir = Directory(folder);
    if (!await dir.exists()) return const [];
    final files = [
      await for (final entry in dir.list())
        if (entry is File && entry.path.endsWith('.json') && !p.basename(entry.path).startsWith('.')) entry,
    ]..sort((a, b) => a.path.compareTo(b.path));
    final requests = <ActionRequest>[];
    for (final file in files) {
      try {
        final text = await file.readAsString();
        await file.delete();
        requests.add(ActionRequest.fromJson((jsonDecode(text) as Map).cast<String, Object?>()));
      } on Object {
        // Gone (taken by someone else) or broken: skip it.
        if (await file.exists()) await file.delete();
      }
    }
    return requests;
  }
}
