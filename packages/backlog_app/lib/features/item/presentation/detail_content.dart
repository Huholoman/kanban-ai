import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../shared/item_style.dart';
import '../../../shared/pr_link.dart';
import '../../../shared/tokens.dart';
import '../application/item_controller.dart';
import 'ask_text.dart';
import 'detail_relations.dart';

/// The scrolling part of the detail: title, state, fields, children,
/// relations and the Markdown body, all editable.
class DetailContent extends StatelessWidget {
  const DetailContent({super.key, required this.controller, required this.onOpen});

  final ItemController controller;

  /// Navigates the panel to a linked item.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final detail = controller.detail!;
    final item = detail.item;
    final workflow = controller.workflow;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TitleField(title: item.title, onSave: (title) => controller.set('title', title)),
              if (item.blocked) ...[const SizedBox(height: 8), _BlockedBy(detail: detail, onOpen: onOpen)],
              const SizedBox(height: 12),
              _Status(item: item),
              if (workflow != null) ...[
                _Pills(
                  field: 'status',
                  label: 'Status',
                  options: [for (final status in workflow.statuses) status.id],
                  selected: item.status,
                  enabled: !controller.busy,
                  onSelect: (status) => controller.set('status', status),
                ),
                const SizedBox(height: 10),
                _Pills(
                  field: 'priority',
                  label: 'Priority',
                  options: workflow.priorities,
                  selected: item.priority,
                  color: (priority) => ItemStyle.priority(priority, workflow),
                  enabled: !controller.busy,
                  onSelect: (priority) => controller.set('priority', priority),
                ),
                const SizedBox(height: 16),
                _Fields(controller: controller, item: item, workflow: workflow),
              ],
              const SizedBox(height: 16),
              DetailChildren(controller: controller, onOpen: onOpen),
              DetailRelations(controller: controller, onOpen: onOpen),
              const SizedBox(height: 16),
              _Body(body: item.body ?? '', onSave: controller.saveBody),
              const SizedBox(height: 12),
              Text(
                [
                  ?item.path,
                  if (item.created != null) 'created ${item.created}',
                  if (item.updated != null) 'updated ${item.updated}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              for (final MapEntry(:key, :value) in item.extra.entries)
                Text('$key: $value', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// The title as a borderless text field; saved on Enter and when it loses
/// focus, an empty title goes back to the saved one.
class _TitleField extends StatefulWidget {
  const _TitleField({required this.title, required this.onSave});

  final String title;
  final Future<bool> Function(String title) onSave;

  @override
  State<_TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<_TitleField> {
  late final _text = TextEditingController(text: widget.title);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_TitleField old) {
    super.didUpdateWidget(old);
    if (widget.title != old.title && !_focus.hasFocus) _text.text = widget.title;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final value = _text.text.replaceAll('\n', ' ').trim();
    if (value.isEmpty) {
      _text.text = widget.title;
    } else if (value != widget.title) {
      unawaited(widget.onSave(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Title', style: theme.textTheme.labelSmall),
        TextField(
          key: const ValueKey('title-field'),
          controller: _text,
          focusNode: _focus,
          maxLines: null,
          textInputAction: TextInputAction.done,
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w600, color: tokens.text),
          decoration: InputDecoration(
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: tokens.accent)),
          ),
          onChanged: (value) {
            if (value.contains('\n')) _focus.unfocus(); // Enter in a multi-line field
          },
          onSubmitted: (_) => _focus.unfocus(),
        ),
      ],
    );
  }
}

/// "Blocked by X-7f3a Production DB backups"; the blockers open in the panel.
class _BlockedBy extends StatelessWidget {
  const _BlockedBy({required this.detail, required this.onOpen});

  final ItemDetailDto detail;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning);
    final titles = {for (final link in detail.dependencies) link.id: link.title};
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      ),
      child: Wrap(
        spacing: 8,
        children: [
          Text('Blocked by', style: style),
          for (final id in detail.item.blockedBy)
            InkWell(
              key: ValueKey('blocker-$id'),
              onTap: () => onOpen(id),
              child: Text([id, ?titles[id]].join(' '), style: style?.copyWith(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

/// A labelled row of radio pills, one per option (statuses, priorities); a
/// tap on another one sets the field.
class _Pills extends StatelessWidget {
  const _Pills({
    required this.field,
    required this.label,
    required this.options,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    this.color,
  });

  final String field;
  final String label;
  final List<String> options;
  final String selected;
  final bool enabled;
  final Future<bool> Function(String value) onSelect;

  /// Colour of the selected pill; the accent when null.
  final Color Function(String value)? color;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    final all = [...options, if (!options.contains(selected)) selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in all)
              Builder(
                builder: (context) {
                  final isSelected = option == selected;
                  final accent = color?.call(option) ?? tokens.accent;
                  return Semantics(
                    inMutuallyExclusiveGroup: true,
                    checked: isSelected,
                    child: Material(
                      key: ValueKey('$field-$option'),
                      color: isSelected
                          ? (color == null ? tokens.accentSoft : accent.withValues(alpha: 0.10))
                          : tokens.surface,
                      shape: StadiumBorder(side: BorderSide(color: isSelected ? accent : tokens.borderStrong)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: !enabled || isSelected ? null : () => unawaited(onSelect(option)),
                        child: Container(
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          child: Text(
                            option,
                            style: TextStyle(
                              fontSize: 12,
                              color: isSelected ? accent : tokens.text,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// The other fields as a definition list: milestone, type, assignee, branch,
/// pull request and labels, each edited in place.
class _Fields extends StatelessWidget {
  const _Fields({required this.controller, required this.item, required this.workflow});

  final ItemController controller;
  final ItemDto item;
  final WorkflowDto workflow;

  @override
  Widget build(BuildContext context) {
    Future<void> editText(String field, String label, String? value) async {
      final edited = await askText(context, label, initial: value ?? '');
      if (edited != null && edited.trim() != (value ?? '')) await controller.set(field, edited.trim());
    }

    return Column(
      children: [
        if (workflow.milestones.isNotEmpty || item.milestone != null)
          _Row(
            label: 'Milestone',
            child: _Choice(
              field: 'milestone',
              value: item.milestone,
              options: [for (final milestone in workflow.milestones) milestone.id],
              optional: true,
              onSelect: (value) => controller.set('milestone', value),
            ),
          ),
        _Row(
          label: 'Type',
          child: _Choice(
            field: 'type',
            value: item.type,
            options: workflow.types,
            onSelect: (value) => controller.set('type', value),
          ),
        ),
        _Row(
          label: 'Assignee',
          child: _Value(
            field: 'assignee',
            text: item.assignee,
            onTap: () => editText('assignee', 'Assignee', item.assignee),
          ),
        ),
        _Row(
          label: 'Branch',
          child: _Value(
            field: 'branch',
            text: item.branch,
            monospace: true,
            onTap: () => editText('branch', 'Branch', item.branch),
          ),
        ),
        _Row(
          label: 'Pull request',
          child: switch (item.pr) {
            final pr? => Row(
              children: [
                PrLink(pr),
                IconButton(
                  key: const ValueKey('field-pr'),
                  tooltip: 'Edit pull request',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => editText('pr', 'Pull request', pr),
                ),
              ],
            ),
            null => _Value(field: 'pr', text: null, onTap: () => editText('pr', 'Pull request', null)),
          },
        ),
        _Row(
          label: 'Labels',
          child: _Labels(item: item, workflow: workflow, controller: controller),
        ),
      ],
    );
  }
}

/// One `label  value` line of the definition list.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 30),
    child: Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ],
    ),
  );
}

/// A text value that opens an editor when tapped; `—` when empty.
class _Value extends StatelessWidget {
  const _Value({required this.field, required this.text, required this.onTap, this.monospace = false});

  final String field;
  final String? text;
  final VoidCallback onTap;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return InkWell(
      key: ValueKey('field-$field'),
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Text(
          text ?? '—',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: text == null ? tokens.faint : tokens.text,
            fontFamily: monospace ? 'monospace' : null,
          ),
        ),
      ),
    );
  }
}

/// A value picked from a menu of [options].
class _Choice extends StatelessWidget {
  const _Choice({
    required this.field,
    required this.value,
    required this.options,
    required this.onSelect,
    this.optional = false,
  });

  /// Stands for "no value" in the menu, which cannot return null.
  static const _none = '';

  final String field;
  final String? value;
  final List<String> options;

  /// Offers `—` to clear the field.
  final bool optional;
  final Future<bool> Function(String? value) onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final all = [if (optional) _none, ...options, if (value != null && !options.contains(value)) value!];
    return PopupMenuButton<String>(
      key: ValueKey('field-$field'),
      tooltip: 'Change $field',
      position: PopupMenuPosition.under,
      onSelected: (selected) {
        final chosen = selected == _none ? null : selected;
        if (chosen != value) unawaited(onSelect(chosen));
      },
      itemBuilder: (_) => [
        for (final option in all)
          CheckedPopupMenuItem(
            value: option,
            checked: option == (value ?? _none),
            child: Text(option == _none ? '—' : option),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value ?? '—', style: TextStyle(fontSize: 12, color: value == null ? tokens.faint : tokens.text)),
            Icon(Icons.arrow_drop_down, size: 16, color: tokens.muted),
          ],
        ),
      ),
    );
  }
}

/// Tags for readiness, the claim and the checklist progress.
class _Status extends StatelessWidget {
  const _Status({required this.item});

  final ItemDto item;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final claim = item.claim;
    final tags = [
      if (item.ready) Tag('ready to pick', icon: Icons.play_arrow, color: tokens.success),
      if (claim != null)
        Tag(
          '${claim.expired ? 'expired claim' : 'claimed'} by ${claim.agent} until ${_time(claim.expiresAt)}',
          icon: Icons.smart_toy_outlined,
          color: claim.expired ? tokens.faint : tokens.warning,
        ),
      if (!item.checklist.isEmpty) Tag('checklist ${item.checklist}', icon: Icons.checklist),
    ];
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(spacing: 6, runSpacing: 6, children: tags),
    );
  }

  static String _time(DateTime moment) {
    final local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.day}.${local.month}. ${two(local.hour)}:${two(local.minute)}';
  }
}

/// Label chips, removable, and a chip that adds more.
class _Labels extends StatelessWidget {
  const _Labels({required this.item, required this.workflow, required this.controller});

  final ItemDto item;
  final WorkflowDto workflow;
  final ItemController controller;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final label in item.labels)
        InputChip(
          key: ValueKey('label-$label'),
          label: Text(label),
          avatar: switch (ItemStyle.label(label, workflow)) {
            final color? => CircleAvatar(backgroundColor: color, radius: 4),
            null => null,
          },
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onDeleted: () => controller.change([ItemUpdateRequest.remove('labels', label)]),
        ),
      ActionChip(
        key: const ValueKey('add-label'),
        avatar: const Icon(Icons.add, size: 14),
        label: const Text('label'),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: () async {
          final label = await askText(context, 'Add labels (comma separated)');
          if (label != null && label.trim().isNotEmpty) {
            await controller.change([ItemUpdateRequest.add('labels', label)]);
          }
        },
      ),
    ],
  );
}

/// Markdown body with an edit mode.
class _Body extends StatefulWidget {
  const _Body({required this.body, required this.onSave});

  final String body;
  final Future<bool> Function(String body) onSave;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  TextEditingController? _editor;

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _editor!.text;
    if (await widget.onSave(text.endsWith('\n') || text.isEmpty ? text : '$text\n')) {
      setState(() {
        _editor?.dispose();
        _editor = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    if (editor != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TextField(
            key: const ValueKey('body-editor'),
            controller: editor,
            minLines: 12,
            maxLines: null,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  editor.dispose();
                  _editor = null;
                }),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Description', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => _editor = TextEditingController(text: widget.body)),
              icon: const Icon(Icons.edit_note),
              label: const Text('Edit'),
            ),
          ],
        ),
        if (widget.body.trim().isEmpty)
          const Text('No description.')
        else
          MarkdownBody(data: widget.body, selectable: true),
      ],
    );
  }
}
