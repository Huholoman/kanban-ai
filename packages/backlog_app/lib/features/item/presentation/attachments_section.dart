import 'dart:async';
import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/files/file_input.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/item_controller.dart';

/// The name of the attachment among [attachments] that the relative link
/// [href] of an item's body names (`shot.png`, `./my%20log.txt`); null for
/// absolute links and other names.
String? attachmentOf(String href, List<AttachmentDto> attachments) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) return null;
  final path = uri.path.startsWith('./') ? uri.path.substring(2) : uri.path;
  final name = Uri.decodeComponent(path);
  return attachments.any((attachment) => attachment.name == name) ? name : null;
}

/// The item's attachments: each opens in a new tab, downloads or is
/// deleted; *Text* attaches a text written or pasted in a dialog, *Files*
/// chosen files. Files dropped onto the page or pasted into it (Ctrl+V)
/// while the detail is open are attached too.
class AttachmentsSection extends StatefulWidget {
  const AttachmentsSection({super.key, required this.controller});

  final ItemController controller;

  /// `512 B`, `12.3 kB`, `4.0 MB`.
  static String size(int bytes) {
    if (bytes < 1000) return '$bytes B';
    if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
    return '${(bytes / 1000 / 1000).toStringAsFixed(1)} MB';
  }

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  final FileInput _files = FileInput.platform();
  StreamSubscription<FileEvent>? _events;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _events = _files.events().listen((event) {
      switch (event) {
        case FileDragEvent(:final dragging):
          setState(() => _dragging = dragging);
        case FilesReceived(:final files):
          unawaited(_attach(files));
      }
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _attach(List<PickedFile> files) async {
    if (files.isEmpty) return;
    await widget.controller.attach([for (final file in files) (file.name, file.bytes)]);
  }

  Future<void> _attachText() async {
    final text = await _askText(context);
    if (text == null) return;
    await widget.controller.attach([(text.$1, utf8.encode(text.$2))]);
  }

  Future<void> _delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('The file is removed from the item.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('attachment-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.detach(name);
  }

  void _open(String name, {bool download = false}) => unawaited(
    launchUrl(
      widget.controller.attachmentUri(name, download: download),
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final attachments = controller.detail!.attachments;
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    final enabled = !controller.busy;
    return Container(
      key: const ValueKey('attachments'),
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 8),
      decoration: BoxDecoration(
        color: _dragging ? tokens.accentSoft : null,
        border: Border.all(color: _dragging ? tokens.accent : tokens.border, width: _dragging ? 2 : 1),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                attachments.isEmpty ? 'Attachments' : 'Attachments · ${attachments.length}',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              LinkButton(
                key: const ValueKey('attach-text'),
                label: 'Text',
                icon: Icons.note_add_outlined,
                onPressed: enabled ? () => unawaited(_attachText()) : null,
              ),
              if (_files.canPick)
                LinkButton(
                  key: const ValueKey('attach-files'),
                  label: 'Files',
                  icon: Icons.attach_file,
                  onPressed: enabled ? () => unawaited(_files.pick().then(_attach)) : null,
                ),
            ],
          ),
          for (final attachment in attachments)
            _AttachmentRow(
              attachment: attachment,
              onOpen: () => _open(attachment.name),
              onDownload: () => _open(attachment.name, download: true),
              onDelete: enabled ? () => unawaited(_delete(attachment.name)) : null,
            ),
          if (_dragging)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('Drop to attach to ${controller.detail!.item.id}.', style: TextStyle(color: tokens.accent)),
            )
          else if (_files.canPick)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                attachments.isEmpty
                    ? 'No attachments. Drop files here or paste them (Ctrl+V).'
                    : 'Drop files here or paste them (Ctrl+V) to add more.',
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.faint),
              ),
            )
          else if (attachments.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('No attachments.', style: TextStyle(color: tokens.faint)),
            ),
        ],
      ),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({required this.attachment, required this.onOpen, required this.onDownload, this.onDelete});

  final AttachmentDto attachment;
  final VoidCallback onOpen;
  final VoidCallback onDownload;

  /// Null while a change is being saved.
  final VoidCallback? onDelete;

  static IconData _icon(String name) {
    final extension = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
    return switch (extension) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' => Icons.image_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'txt' || 'md' || 'log' || 'json' || 'yaml' || 'yml' || 'csv' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return Row(
      key: ValueKey('attachment-${attachment.name}'),
      children: [
        Icon(_icon(attachment.name), size: 18, color: tokens.muted),
        const SizedBox(width: 6),
        Flexible(
          child: Tooltip(
            message: 'Open in a new tab',
            child: InkWell(
              borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text(
                  attachment.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.accent),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(AttachmentsSection.size(attachment.size), style: small?.copyWith(color: tokens.muted)),
        const Spacer(),
        IconActionButton(
          key: ValueKey('attachment-download-${attachment.name}'),
          tooltip: 'Download',
          icon: Icons.download_outlined,
          size: 18,
          box: 30,
          onPressed: onDownload,
        ),
        IconActionButton(
          key: ValueKey('attachment-delete-${attachment.name}'),
          tooltip: 'Delete',
          icon: Icons.delete_outline,
          size: 18,
          box: 30,
          onPressed: onDelete,
        ),
      ],
    );
  }
}

/// Asks for the name and content of a text attachment; null when cancelled.
Future<(String, String)?> _askText(BuildContext context) {
  final name = TextEditingController(text: 'text.txt');
  final text = TextEditingController();
  return showDialog<(String, String)>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Attach a text'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('attachment-name'),
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('attachment-text'),
              controller: text,
              autofocus: true,
              minLines: 10,
              maxLines: 20,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Write or paste the text (a log, an error, notes…)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        LinkButton(label: 'Cancel', onPressed: () => Navigator.of(dialogContext).pop()),
        ListenableBuilder(
          listenable: Listenable.merge([name, text]),
          builder: (context, _) => PrimaryButton(
            key: const ValueKey('attachment-text-save'),
            label: 'Attach',
            onPressed: name.text.trim().isEmpty || text.text.isEmpty
                ? null
                : () => Navigator.of(dialogContext).pop((name.text.trim(), text.text)),
          ),
        ),
      ],
    ),
  );
}
