import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

/// Asks for the fields of a new item; returns null when cancelled.
Future<NewItemRequest?> showNewItemDialog(BuildContext context, WorkflowDto workflow) =>
    showDialog<NewItemRequest>(context: context, builder: (_) => _NewItemDialog(workflow));

class _NewItemDialog extends StatefulWidget {
  const _NewItemDialog(this.workflow);

  final WorkflowDto workflow;

  @override
  State<_NewItemDialog> createState() => _NewItemDialogState();
}

class _NewItemDialogState extends State<_NewItemDialog> {
  final _title = TextEditingController();
  final _labels = TextEditingController();
  final _body = TextEditingController();
  late String _type = widget.workflow.defaultType;
  late String _status = widget.workflow.defaultStatus;
  late String _priority = widget.workflow.defaultPriority;
  String? _milestone;

  @override
  void dispose() {
    _title.dispose();
    _labels.dispose();
    _body.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      NewItemRequest(
        title: title,
        type: _type,
        status: _status,
        priority: _priority,
        milestone: _milestone,
        labels: _labels.text.split(',').map((l) => l.trim()).where((l) => l.isNotEmpty).toList(),
        body: _body.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workflow = widget.workflow;
    Widget picker(String label, String? value, List<String?> options, ValueChanged<String?> onChanged) => SizedBox(
      width: 160,
      child: DropdownButtonFormField<String?>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [for (final option in options) DropdownMenuItem(value: option, child: Text(option ?? '—'))],
        onChanged: (selected) => setState(() => onChanged(selected)),
      ),
    );

    return AlertDialog(
      title: const Text('New item'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('new-title'),
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  picker('Type', _type, workflow.types, (v) => _type = v!),
                  picker('Status', _status, [for (final s in workflow.statuses) s.id], (v) => _status = v!),
                  picker('Priority', _priority, workflow.priorities, (v) => _priority = v!),
                  if (workflow.milestones.isNotEmpty)
                    picker('Milestone', _milestone, [
                      null,
                      for (final m in workflow.milestones) m.id,
                    ], (v) => _milestone = v),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _labels,
                decoration: const InputDecoration(labelText: 'Labels', hintText: 'comma separated'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                minLines: 4,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'Description (Markdown)', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
