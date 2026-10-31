import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';

import '../render/json_output.dart';
import 'backlog_command.dart';

/// `backlog check|uncheck <id> [<n>… | <text…>]`: ticks checklist items of
/// an item's body without editing its file (agents work outside the backlog
/// folder); without a selector it lists the numbered checklist.
abstract class _ChecklistCommand extends BacklogCommand {
  _ChecklistCommand(super.context);

  bool get done;

  @override
  String get invocation => 'backlog $name <id> [<number>… | <text…>]';

  @override
  Future<int> run() async {
    if (args.rest.isEmpty) throw UsageException('Expected an item id.', usage);
    final backlog = await openBacklog();
    final words = args.rest.skip(1).toList();
    if (words.isEmpty) {
      final item = await backlog.items.get(args.rest.first);
      return _emit(backlog, item.id, Checklist.entriesOf(item.body), changed: const []);
    }
    // Only numbers: each names an item; otherwise the words are one text.
    final numbers = words.every((word) => RegExp(r'^\d+$').hasMatch(word));
    final update = await backlog.items.check(args.rest.first, numbers ? words : [words.join(' ')], done: done);
    final verb = done ? 'Checked' : 'Unchecked';
    final already = update.selected.where((entry) => !update.changed.contains(entry.number));
    return _emit(
      backlog,
      update.item.id,
      update.entries,
      changed: update.changed,
      message: [
        if (update.changed.isNotEmpty) '$verb ${update.changed.join(', ')} on ${update.item.id}.',
        if (already.isNotEmpty)
          '${already.map((entry) => entry.number).join(', ')} ${already.length == 1 ? 'was' : 'were'} '
              '${done ? 'checked' : 'unchecked'} already.',
      ].join(' '),
    );
  }

  Future<int> _emit(
    Backlog backlog,
    ItemId id,
    List<ChecklistEntry> entries, {
    required List<int> changed,
    String? message,
  }) async {
    if (json) {
      final snapshot = await backlog.planning.snapshot();
      emitJson({
        ...JsonOutput.item(snapshot[id]!, path: await backlog.items.locationOf(id)),
        'checklist': [for (final entry in entries) JsonOutput.checklistEntry(entry)],
        'changed': changed,
      });
      return 0;
    }
    if (message != null && message.isNotEmpty) line(message);
    if (entries.isEmpty) {
      line('$id has no checklist.');
      return 0;
    }
    final finished = entries.where((entry) => entry.done).length;
    line('Checklist of $id ($finished/${entries.length}):');
    lines([for (final entry in entries) '  $entry']);
    return 0;
  }
}

final class CheckCommand extends _ChecklistCommand {
  CheckCommand(super.context);

  @override
  String get name => 'check';

  @override
  String get description =>
      'Tick checklist items (`- [ ]` lines) of an item by number or text, without editing its file; '
      'without them list the numbered checklist.';

  @override
  bool get done => true;
}

final class UncheckCommand extends _ChecklistCommand {
  UncheckCommand(super.context);

  @override
  String get name => 'uncheck';

  @override
  String get description => 'Untick checklist items of an item by number or text (see `check`).';

  @override
  bool get done => false;
}
