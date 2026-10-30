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
              _EditableTitle(title: item.title, onSave: (title) => controller.set('title', title)),
              if (item.blocked) ...[const SizedBox(height: 8), _BlockedBy(detail: detail, onOpen: onOpen)],
              const SizedBox(height: 12),
              _Status(item: item),
              if (workflow != null) _Fields(controller: controller, item: item, workflow: workflow),
              const SizedBox(height: 12),
              _Labels(item: item, controller: controller),
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

class _EditableTitle extends StatelessWidget {
  const _EditableTitle({required this.title, required this.onSave});

  final String title;
  final Future<bool> Function(String title) onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: SelectableText(title, style: Theme.of(context).textTheme.headlineSmall)),
        IconButton(
          tooltip: 'Rename',
          icon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: () async {
            final value = await askText(context, 'Title', initial: title);
            if (value != null && value.trim().isNotEmpty && value != title) await onSave(value.trim());
          },
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

class _Fields extends StatelessWidget {
  const _Fields({required this.controller, required this.item, required this.workflow});

  final ItemController controller;
  final ItemDto item;
  final WorkflowDto workflow;

  @override
  Widget build(BuildContext context) {
    Widget picker(String field, String label, String? value, List<String> options, {bool optional = false}) {
      final all = [if (optional) null, ...options, if (value != null && !options.contains(value)) value];
      return SizedBox(
        width: 170,
        child: DropdownButtonFormField<String?>(
          key: ValueKey('field-$field-$value'),
          value: value,
          isDense: true,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          items: [
            for (final option in all)
              DropdownMenuItem(
                value: option,
                child: Text(option ?? '—', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: controller.busy
              ? null
              : (selected) => selected == value ? null : unawaited(controller.set(field, selected)),
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        picker('status', 'Status', item.status, [for (final s in workflow.statuses) s.id]),
        picker('priority', 'Priority', item.priority, workflow.priorities),
        picker('type', 'Type', item.type, workflow.types),
        if (workflow.milestones.isNotEmpty || item.milestone != null)
          picker('milestone', 'Milestone', item.milestone, [for (final m in workflow.milestones) m.id], optional: true),
        _TextField(label: 'Assignee', value: item.assignee, onSave: (v) => controller.set('assignee', v)),
        _TextField(label: 'Branch', value: item.branch, onSave: (v) => controller.set('branch', v)),
        _TextField(label: 'Pull request', value: item.pr, onSave: (v) => controller.set('pr', v)),
      ],
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({required this.label, required this.value, required this.onSave});

  final String label;
  final String? value;
  final Future<bool> Function(String value) onSave;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    child: InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final edited = await askText(context, label, initial: value ?? '');
        if (edited != null && edited.trim() != (value ?? '')) await onSave(edited.trim());
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        child: Text(value ?? '—', overflow: TextOverflow.ellipsis),
      ),
    ),
  );
}

/// Tags for the PR, readiness, the claim and the checklist progress.
class _Status extends StatelessWidget {
  const _Status({required this.item});

  final ItemDto item;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final claim = item.claim;
    final tags = [
      if (item.pr case final pr?) PrLink(pr),
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

class _Labels extends StatelessWidget {
  const _Labels({required this.item, required this.controller});

  final ItemDto item;
  final ItemController controller;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final label in item.labels)
        InputChip(
          label: Text('#$label'),
          visualDensity: VisualDensity.compact,
          onDeleted: () => controller.change([ItemUpdateRequest.remove('labels', label)]),
        ),
      ActionChip(
        avatar: const Icon(Icons.add, size: 16),
        label: const Text('label'),
        visualDensity: VisualDensity.compact,
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
