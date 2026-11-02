import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../render/json_output.dart';
import '../render/text_output.dart';
import 'backlog_command.dart';

/// `backlog attach <id> [<file>…] [--text t --name n] [--replace]`: attaches
/// files or a text to an item (stored next to its file); without them lists
/// its attachments.
final class AttachCommand extends BacklogCommand {
  AttachCommand(super.context) {
    argParser
      ..addOption(
        'text',
        abbr: 't',
        help: 'Attach this text instead of files (- reads standard input).',
        valueHelp: 'text',
      )
      ..addOption(
        'name',
        abbr: 'n',
        help: 'Name of the attachment (with --text, default text.txt, or with a single file).',
        valueHelp: 'name',
      )
      ..addFlag('replace', negatable: false, help: 'Replace an attachment of the same name (else: name-2.ext).')
      ..addFlag(
        'export',
        negatable: false,
        help: 'Copy the attachments into .kanban-ai/attachments/<id>/ here (or --to), e.g. into a worktree.',
      )
      ..addOption('to', help: 'The folder --export copies into.', valueHelp: 'folder');
  }

  @override
  String get name => 'attach';

  @override
  String get description =>
      'Attach files or a text to an item (stored next to its file); without them list its attachments; '
      '--export copies them here.';

  @override
  String get invocation =>
      'backlog attach <id> [<file>… | --text "<text>"] [--name <name>] [--replace] | <id> --export [--to <folder>]';

  @override
  Future<int> run() async {
    if (args.rest.isEmpty) throw UsageException('Expected an item id.', usage);
    final reference = args.rest.first;
    final files = args.rest.skip(1).toList();
    final text = args.option('text');
    final name = args.option('name');
    if (args.flag('export') || args.option('to') != null) {
      if (files.isNotEmpty || text != null || name != null) {
        throw UsageException('--export takes only the item id (and --to).', usage);
      }
      return _export(reference);
    }
    if (text != null && files.isNotEmpty) throw UsageException('Give files or --text, not both.', usage);
    if (name != null && text == null && files.length != 1) {
      throw UsageException('--name needs --text or exactly one file.', usage);
    }

    final contents = <(String, List<int>)>[];
    if (text != null) {
      final value = text == '-'
          ? await (context.readInput ?? (throw UsageException('No standard input to read.', usage)))()
          : text;
      contents.add((name ?? 'text.txt', utf8.encode(value)));
    }
    for (final file in files) {
      final path = p.normalize(p.join(context.cwd, file));
      try {
        contents.add((name ?? p.basename(path), await File(path).readAsBytes()));
      } on FileSystemException catch (error) {
        throw InvalidInputException('Cannot read $path: ${error.osError?.message ?? error.message}.');
      }
    }

    final backlog = await openBacklog();
    final item = await backlog.items.get(reference);
    final attached = [
      for (final (name, content) in contents)
        await backlog.items.attach(item.id.value, name, content, replace: args.flag('replace')),
    ];
    return emitAttachments(
      backlog,
      item.id,
      changed: [for (final attachment in attached) attachment.name],
      key: 'attached',
      message: [for (final attachment in attached) 'Attached ${TextOutput.attachmentLine(attachment)} to ${item.id}.'],
    );
  }
}

extension on AttachCommand {
  /// Copies the item's attachments into a folder outside the backlog (by
  /// default `.kanban-ai/attachments/<id>/` of the current folder, where the
  /// dispatcher puts those of an agent's item).
  Future<int> _export(String reference) async {
    final backlog = await openBacklog();
    final id = (await backlog.items.get(reference)).id;
    final folder = p.normalize(p.join(context.cwd, args.option('to') ?? DispatcherConfig.attachmentsFolder(id.value)));
    final written = await exportAttachments(backlog.items, id, folder);
    if (this.json) {
      final snapshot = await backlog.planning.snapshot();
      final attachments = await backlog.items.attachmentsOf(id);
      emitJson({
        ...JsonOutput.item(snapshot[id]!, path: await backlog.items.locationOf(id), attachments: attachments),
        'exported': written,
      });
      return 0;
    }
    if (written.isEmpty) {
      line('$id has no attachments.');
    } else {
      line('Copied ${written.length} attachment(s) of $id to $folder:');
      lines([for (final path in written) '  $path']);
    }
    return 0;
  }
}

/// `backlog detach <id> <name>…`: deletes attachments of an item.
final class DetachCommand extends BacklogCommand {
  DetachCommand(super.context);

  @override
  String get name => 'detach';

  @override
  String get description => 'Delete attachments of an item by name.';

  @override
  String get invocation => 'backlog detach <id> <name>…';

  @override
  Future<int> run() async {
    if (args.rest.length < 2) throw UsageException('Expected an item id and the names of attachments.', usage);
    final backlog = await openBacklog();
    final item = await backlog.items.get(args.rest.first);
    final names = args.rest.skip(1).toList();
    for (final name in names) {
      await backlog.items.detach(item.id.value, name);
    }
    return emitAttachments(
      backlog,
      item.id,
      changed: names,
      key: 'removed',
      message: ['Removed ${names.join(', ')} from ${item.id}.'],
    );
  }
}

extension on BacklogCommand {
  /// The item's attachments after a change: JSON the item with
  /// `attachments` and the names [changed] under [key], text the [message]
  /// and a line per attachment with its path.
  Future<int> emitAttachments(
    Backlog backlog,
    ItemId id, {
    required List<String> changed,
    required String key,
    List<String> message = const [],
  }) async {
    final attachments = await backlog.items.attachmentsOf(id);
    final path = await backlog.items.locationOf(id);
    if (this.json) {
      final snapshot = await backlog.planning.snapshot();
      emitJson({...JsonOutput.item(snapshot[id]!, path: path, attachments: attachments), key: changed});
      return 0;
    }
    lines(message);
    if (attachments.isEmpty) {
      line('$id has no attachments.');
      return 0;
    }
    line('Attachments of $id:');
    lines([
      for (final attachment in attachments)
        '  ${TextOutput.attachmentLine(attachment)}  ${TextOutput.attachmentPath(attachment, path) ?? ''}'.trimRight(),
    ]);
    return 0;
  }
}
