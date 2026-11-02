import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/item_service.dart';
import '../domain/item_id.dart';

/// Copies the attachments of item [id] into [folder] (created when missing),
/// so that an agent can read them inside its worktree, where the backlog's
/// own files are out of its reach. Returns the paths written, by name.
///
/// With [prune] the files of [folder] that are no longer attachments are
/// removed, and the folder itself when there are none: only for a folder
/// that holds nothing but this item's attachments (its own
/// `.kanban-ai/attachments/<id>/`), never for one a person names, which may
/// hold anything.
Future<List<String>> exportAttachments(ItemService items, ItemId id, String folder, {bool prune = false}) async {
  final attachments = await items.attachmentsOf(id);
  final directory = Directory(folder);
  final names = {for (final attachment in attachments) attachment.name};
  if (prune && await directory.exists()) {
    await for (final entity in directory.list(followLinks: false)) {
      if (!names.contains(p.basename(entity.path))) await entity.delete(recursive: true);
    }
    if (names.isEmpty) await directory.delete(recursive: true);
  }
  final written = <String>[];
  for (final attachment in attachments) {
    final file = File(p.join(folder, attachment.name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await items.readAttachment(id.value, attachment.name), flush: true);
    written.add(file.path);
  }
  return written;
}
