import 'package:flutter/material.dart';

/// Asks for one line of text in a dialog; null when cancelled.
Future<String?> askText(BuildContext context, String label, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(label),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text), child: const Text('OK')),
      ],
    ),
  );
}
