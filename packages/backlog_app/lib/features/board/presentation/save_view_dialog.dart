import 'package:flutter/material.dart';

/// Asks for the name and section of a view saved from the filter. Pops
/// `(name, section)`, or null when cancelled.
Future<(String, String?)?> showSaveViewDialog(
  BuildContext context, {
  required String suggestedName,
  required List<String> sections,
}) => showDialog<(String, String?)>(
  context: context,
  builder: (_) => _SaveViewDialog(suggestedName: suggestedName, sections: sections),
);

class _SaveViewDialog extends StatefulWidget {
  const _SaveViewDialog({required this.suggestedName, required this.sections});

  final String suggestedName;
  final List<String> sections;

  @override
  State<_SaveViewDialog> createState() => _SaveViewDialogState();
}

class _SaveViewDialogState extends State<_SaveViewDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _section = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _section.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final section = _section.text.trim();
    Navigator.of(context).pop((name, section.isEmpty ? null : section));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as view'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Keeps the layout, grouping and columns of the current view and adds the current filter.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('save-view-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('save-view-section'),
            controller: _section,
            decoration: const InputDecoration(labelText: 'Section (optional)'),
            onSubmitted: (_) => _save(),
          ),
          if (widget.sections.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final section in widget.sections)
                  ActionChip(label: Text(section), onPressed: () => setState(() => _section.text = section)),
              ],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
