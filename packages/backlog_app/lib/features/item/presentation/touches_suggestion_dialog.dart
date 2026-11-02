import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/ui/ui.dart';

/// Shows a model's estimate of an item's touches for a person to confirm:
/// each new entry as a checkbox (ticked), the entries left out with their
/// reason, and a field for more paths. The paths to add; null when
/// cancelled.
Future<List<String>?> confirmTouches(BuildContext context, TouchesSuggestionDto suggestion, List<String> current) =>
    showDialog<List<String>>(
      context: context,
      builder: (_) => _TouchesSuggestionDialog(suggestion: suggestion, current: current),
    );

class _TouchesSuggestionDialog extends StatefulWidget {
  const _TouchesSuggestionDialog({required this.suggestion, required this.current});

  final TouchesSuggestionDto suggestion;
  final List<String> current;

  @override
  State<_TouchesSuggestionDialog> createState() => _TouchesSuggestionDialogState();
}

class _TouchesSuggestionDialogState extends State<_TouchesSuggestionDialog> {
  late final List<String> _new = [
    for (final entry in widget.suggestion.suggested)
      if (!widget.current.contains(entry)) entry,
  ];
  late final Set<String> _chosen = {..._new};
  final _more = TextEditingController();

  @override
  void dispose() {
    _more.dispose();
    super.dispose();
  }

  List<String> get _result => [
    for (final entry in _new)
      if (_chosen.contains(entry)) entry,
    if (_more.text.trim().isNotEmpty) _more.text.trim(),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);
    final known = widget.suggestion.suggested.length - _new.length;
    return AlertDialog(
      title: const Text('Suggested touches'),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_new.isEmpty)
              Text(
                widget.suggestion.suggested.isEmpty
                    ? 'The model suggested no paths.'
                    : 'The item has every suggested path already.',
              ),
            for (final entry in _new)
              CheckboxListTile(
                key: ValueKey('suggested-$entry'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(entry, style: mono),
                value: _chosen.contains(entry),
                onChanged: (on) => setState(() => on == true ? _chosen.add(entry) : _chosen.remove(entry)),
              ),
            if (known > 0)
              Text(
                '$known suggested ${known == 1 ? 'path is' : 'paths are'} among the touches already.',
                style: theme.textTheme.bodySmall,
              ),
            if (widget.suggestion.rejected.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Left out', style: theme.textTheme.labelMedium),
              for (final rejected in widget.suggestion.rejected)
                Text(
                  '${rejected.entry} — ${rejected.reason}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('more-touches'),
              controller: _more,
              style: mono,
              decoration: const InputDecoration(labelText: 'More paths or globs (comma separated)', isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        LinkButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(
          key: const ValueKey('add-suggested-touches'),
          label: 'Add',
          onPressed: _result.isEmpty ? null : () => Navigator.of(context).pop(_result),
        ),
      ],
    );
  }
}
