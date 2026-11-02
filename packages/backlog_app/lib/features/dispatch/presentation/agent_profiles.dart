import 'package:flutter/material.dart';

import '../application/dispatch_controller.dart';

class AgentProfiles extends StatelessWidget {
  const AgentProfiles({super.key, required this.dispatch});
  final DispatchController dispatch;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: DropdownButton<String>(
          isExpanded: true,
          hint: const Text('Agent profile'),
          value: dispatch.profiles.containsKey(dispatch.selectedAgent) ? dispatch.selectedAgent : null,
          items: [for (final name in dispatch.profiles.keys) DropdownMenuItem(value: name, child: Text(name))],
          onChanged: dispatch.pending.contains('profiles')
              ? null
              : (name) {
                  if (name != null) dispatch.saveProfiles({'agent': name});
                },
        ),
      ),
      IconButton(
        tooltip: 'Define an agent profile',
        icon: const Icon(Icons.add),
        onPressed: dispatch.pending.contains('profiles') ? null : () => _add(context),
      ),
    ],
  );

  Future<void> _add(BuildContext context) async {
    var name = '';
    var command = '';
    var output = 'text';
    final form = GlobalKey<FormState>();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Define an agent profile'),
          content: SizedBox(
            width: 480,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    onChanged: (value) => name = value,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (value) => !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value?.trim() ?? '')
                        ? 'Use letters, digits, dots, underscores or hyphens.'
                        : dispatch.profiles.containsKey(value?.trim())
                        ? 'This profile already exists.'
                        : null,
                  ),
                  TextFormField(
                    onChanged: (value) => command = value,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      helperText: 'Example: my-agent --prompt {prompt}',
                    ),
                    validator: (value) => value == null || value.trim().isEmpty ? 'Enter a command.' : null,
                  ),
                  DropdownButtonFormField<String>(
                    value: output,
                    decoration: const InputDecoration(labelText: 'Output format'),
                    items: [
                      for (final value in ['text', 'claude-stream-json', 'json-lines'])
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) => update(() => output = value!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, {
                    'profile': {'name': name.trim(), 'command': command.trim(), 'output': output},
                    'agent': name.trim(),
                  });
                }
              },
              child: const Text('Save and select'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await dispatch.saveProfiles(result);
  }
}
