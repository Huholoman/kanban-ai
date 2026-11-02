import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/item_service.dart';
import '../domain/item_id.dart';

/// Copies the attachments of item [id] into [folder] (created when missing),
/// so that an agent can read them inside its worktree, where the backlog's
/// own files are out of its reach. Files of [folder] that are no longer
/// attachments are removed; the folder is removed when there are none.
/// Returns the paths written, by name.
Future<List<String>> exportAttachments(ItemService items, ItemId id, String folder) async {
  final attachments = await items.attachmentsOf(id);
  final directory = Directory(folder);
  final names = {for (final attachment in attachments) attachment.name};
  if (await directory.exists()) {
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
