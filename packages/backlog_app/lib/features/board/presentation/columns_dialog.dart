import 'package:flutter/material.dart';

/// Picks and orders the columns (groups) of a view. Pops the chosen columns,
/// an empty list for "back to the default", or null when cancelled.
Future<List<String>?> showColumnsDialog(
  BuildContext context, {
  required String field,
  required List<String> options,
  required List<String> shown,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _ColumnsDialog(field: field, options: options, shown: shown),
);

class _ColumnsDialog extends StatefulWidget {
  const _ColumnsDialog({required this.field, required this.options, required this.shown});

  final String field;
  final List<String> options;
  final List<String> shown;

  @override
  State<_ColumnsDialog> createState() => _ColumnsDialogState();
}

class _ColumnsDialogState extends State<_ColumnsDialog> {
  /// Shown columns first in their order, then the hidden ones.
  late final List<String> _order = [
    ...widget.shown,
    ...widget.options.where((option) => !widget.shown.contains(option)),
  ];
  late final Set<String> _checked = {...widget.shown};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Columns by ${widget.field}'),
    content: SizedBox(
      width: 360,
      height: 56.0 * _order.length.clamp(3, 9),
      child: ReorderableListView(
        buildDefaultDragHandles: false,
        onReorder: (from, to) => setState(() {
          final moved = _order.removeAt(from);
          _order.insert(to > from ? to - 1 : to, moved);
        }),
        children: [
          for (final (index, column) in _order.indexed)
            CheckboxListTile(
              key: ValueKey('column-$column'),
              value: _checked.contains(column),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(column),
              secondary: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
              onChanged: (checked) => setState(() => checked == true ? _checked.add(column) : _checked.remove(column)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(const <String>[]), child: const Text('Default')),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: _checked.isEmpty
            ? null
            : () => Navigator.of(context).pop([
                for (final column in _order)
                  if (_checked.contains(column)) column,
              ]),
        child: const Text('Save'),
      ),
    ],
  );
}
