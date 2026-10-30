import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';

/// Asks for the name, section and pinning of a view saved from the filter.
/// Pops `(name, section, pinned)`, or null when cancelled.
Future<(String, String?, bool)?> showSaveViewDialog(
  BuildContext context, {
  required String suggestedName,
  required List<String> sections,
}) => showDialog<(String, String?, bool)>(
  context: context,
  builder: (_) => _SaveViewDialog(suggestedName: suggestedName, sections: sections),
);

/// File name a view called [name] is saved under: lowercase, runs of other
/// characters become one `-`.
String viewSlug(String name) {
  final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'view' : slug;
}

class _SaveViewDialog extends StatefulWidget {
  const _SaveViewDialog({required this.suggestedName, required this.sections});

  final String suggestedName;
  final List<String> sections;

  @override
  State<_SaveViewDialog> createState() => _SaveViewDialogState();
}

class _SaveViewDialogState extends State<_SaveViewDialog> {
  static const _none = '';
  static const _create = '+';

  late final _name = TextEditingController(text: widget.suggestedName);
  final _newSection = TextEditingController();

  /// [_none], [_create] or the name of an existing section; without existing
  /// sections the dialog starts with the text field.
  late String _choice = widget.sections.isEmpty ? _create : _none;
  bool _pinned = false;

  @override
  void dispose() {
    _name.dispose();
    _newSection.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final section = switch (_choice) {
      _none => '',
      _create => _newSection.text.trim(),
      final existing => existing,
    };
    Navigator.of(context).pop((name, section.isEmpty ? null : section, _pinned));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final labelStyle = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: const Text('Save as view'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name', style: labelStyle),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('save-view-name'),
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            Text('Section in the left panel', style: labelStyle),
            const SizedBox(height: 4),
            if (_choice == _create)
              TextField(
                key: const ValueKey('save-view-section'),
                controller: _newSection,
                autofocus: widget.sections.isNotEmpty,
                decoration: InputDecoration(
                  hintText: 'New section name',
                  suffixIcon: widget.sections.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Pick an existing section',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setState(() => _choice = _none),
                        ),
                ),
                onSubmitted: (_) => _save(),
              )
            else
              DropdownButtonFormField<String>(
                key: const ValueKey('save-view-section'),
                value: _choice,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: _none, child: Text('No section')),
                  for (final section in widget.sections) DropdownMenuItem(value: section, child: Text(section)),
                  const DropdownMenuItem(value: _create, child: Text('+ New section…')),
                ],
                onChanged: (value) => setState(() => _choice = value ?? _none),
              ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const ValueKey('save-view-pin'),
              value: _pinned,
              onChanged: (value) => setState(() => _pinned = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Pin to the bottom bar (mobile)'),
            ),
            const SizedBox(height: 4),
            Text(
              'Saved as views/${viewSlug(_name.text)}.yaml (filter + columns + sorting)',
              style: labelStyle?.copyWith(color: tokens.muted),
            ),
          ],
        ),
      ),
      actions: [
        LinkButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(label: 'Save', onPressed: _save),
      ],
    );
  }
}
