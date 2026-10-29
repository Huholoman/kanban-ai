import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An item id that copies itself to the clipboard when clicked, e.g. to paste
/// it to an agent.
class CopyableId extends StatelessWidget {
  const CopyableId(this.id, {super.key, this.style});

  final String id;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Copy id',
    child: InkWell(
      key: ValueKey('copy-$id'),
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: id));
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Copied $id'), duration: const Duration(seconds: 2)));
      },
      child: Text(id, style: style, overflow: TextOverflow.ellipsis),
    ),
  );
}
