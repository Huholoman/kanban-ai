import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/new_item_defaults.dart';

/// Asks for the fields of a new item; returns null when cancelled. The
/// parent is searched among [candidates] by id or title; with [parent] the
/// item starts under it, with the child type of its type
/// ([NewItemDefaults.childType]). Narrower than [newItemPageBelow] (phones)
/// it is a full page, so the keyboard leaves room for the field typed in.
Future<NewItemRequest?> showNewItemDialog(
  BuildContext context,
  WorkflowDto workflow, {
  List<ItemDto> candidates = const [],
  ItemDto? parent,
}) {
  if (MediaQuery.sizeOf(context).width < newItemPageBelow) {
    return Navigator.of(context).push(
      MaterialPageRoute<NewItemRequest>(
        fullscreenDialog: true,
        builder: (_) => _NewItemDialog(workflow, candidates: candidates, parent: parent, page: true),
      ),
    );
  }
  return showDialog<NewItemRequest>(
    context: context,
    builder: (_) => _NewItemDialog(workflow, candidates: candidates, parent: parent),
  );
}

/// Below this width *New item* is a full page; the phone layout of the board
/// starts at the same width.
const newItemPageBelow = 600.0;

class _NewItemDialog extends StatefulWidget {
  const _NewItemDialog(this.workflow, {required this.candidates, this.parent, this.page = false});

  final WorkflowDto workflow;
  final List<ItemDto> candidates;
  final ItemDto? parent;

  /// A full page instead of a dialog.
  final bool page;

  @override
  State<_NewItemDialog> createState() => _NewItemDialogState();
}

class _NewItemDialogState extends State<_NewItemDialog> {
  final _title = TextEditingController();
  final _labels = TextEditingController();
  final _body = TextEditingController();
  late ItemDto? _parent = widget.parent;
  late String _type = switch (widget.parent) {
    final parent? => NewItemDefaults.childType(parent.type, widget.workflow),
    null => widget.workflow.defaultType,
  };

  /// The type was picked by hand, so choosing a parent keeps it.
  bool _typeChosen = false;
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
        parent: _parent?.id,
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

    final page = widget.page;
    final fields = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
            picker('Type', _type, workflow.types, (v) {
              _type = v!;
              _typeChosen = true;
            }),
            picker('Status', _status, [for (final s in workflow.statuses) s.id], (v) => _status = v!),
            picker('Priority', _priority, workflow.priorities, (v) => _priority = v!),
            if (workflow.milestones.isNotEmpty)
              picker('Milestone', _milestone, [null, for (final m in workflow.milestones) m.id], (v) => _milestone = v),
          ],
        ),
        const SizedBox(height: 12),
        _parentField(),
        const SizedBox(height: 12),
        TextField(
          controller: _labels,
          decoration: const InputDecoration(labelText: 'Labels', hintText: 'comma separated'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('new-body'),
          controller: _body,
          minLines: page ? 8 : 4,
          maxLines: page ? null : 12,
          decoration: const InputDecoration(labelText: 'Description (Markdown)', border: OutlineInputBorder()),
        ),
      ],
    );

    if (page) {
      // The page shrinks above the keyboard and the focused field scrolls
      // into view, so what is typed in the description stays visible.
      return Scaffold(
        key: const ValueKey('new-item-page'),
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('New item'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: PrimaryButton(label: 'Create', onPressed: _submit),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: fields),
        ),
      );
    }
    return AlertDialog(
      title: const Text('New item'),
      content: SizedBox(width: 560, child: SingleChildScrollView(child: fields)),
      actions: [
        LinkButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(label: 'Create', onPressed: _submit),
      ],
    );
  }

  void _chooseParent(ItemDto? parent) => setState(() {
    _parent = parent;
    if (parent != null && !_typeChosen) _type = NewItemDefaults.childType(parent.type, widget.workflow);
  });

  /// The chosen parent with × to clear it, else a search by id or title.
  Widget _parentField() {
    final tokens = BoardTokens.of(context);
    if (_parent case final parent?) {
      return InputDecorator(
        key: const ValueKey('new-parent'),
        decoration: InputDecoration(
          labelText: 'Parent',
          isDense: true,
          suffixIcon: IconActionButton(
            key: const ValueKey('new-parent-clear'),
            tooltip: 'No parent',
            icon: Icons.close,
            size: 18,
            onPressed: () => _chooseParent(null),
          ),
        ),
        child: Text('${parent.id} ${parent.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    return Autocomplete<ItemDto>(
      key: const ValueKey('new-parent-search'),
      displayStringForOption: (item) => '${item.id} ${item.title}',
      optionsBuilder: (value) => NewItemDefaults.search(widget.candidates, value.text),
      onSelected: _chooseParent,
      fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
        key: const ValueKey('new-parent-field'),
        controller: controller,
        focusNode: focus,
        decoration: const InputDecoration(labelText: 'Parent', hintText: 'optional: search by id or title'),
        onSubmitted: (_) => onSubmitted(),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          color: tokens.surface,
          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final item in options)
                  ListTile(
                    key: ValueKey('parent-option-${item.id}'),
                    dense: true,
                    leading: Icon(ItemStyle.type(item.type), size: 16, color: tokens.muted),
                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${item.id} · ${item.type} · ${item.status}'),
                    onTap: () => onSelected(item),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
