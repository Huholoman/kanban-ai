import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../app/app_scope.dart';
import '../../../shared/copyable_id.dart';
import '../../../shared/item_style.dart';
import '../../../shared/pr_link.dart';
import '../application/item_controller.dart';

/// The item detail as a full screen, for narrow windows.
class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ItemDetailView(
        reference: reference,
        closeIcon: Icons.arrow_back,
        onClose: () => Navigator.of(context).pop(),
        onOpen: (id) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ItemPage(reference: id))),
      ),
    ),
  );
}

/// Detail of one item: fields, relations and the Markdown body, all editable.
/// Used as a page and as the side panel next to the board; give it a key per
/// [reference] so that a different item gets a fresh controller.
class ItemDetailView extends StatefulWidget {
  const ItemDetailView({
    super.key,
    required this.reference,
    required this.onOpen,
    this.onClose,
    this.closeIcon = Icons.close,
    this.openChildId,
  });

  final String reference;

  /// Child shown in the panel to the right, highlighted in the list.
  final String? openChildId;

  /// Opens a related item.
  final void Function(String id) onOpen;
  final VoidCallback? onClose;
  final IconData closeIcon;

  @override
  State<ItemDetailView> createState() => _ItemDetailViewState();
}

class _ItemDetailViewState extends State<ItemDetailView> {
  ItemController? _controller;
  StreamSubscription<String>? _notices;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final scope = AppScope.of(context);
    final controller = _controller = ItemController(scope.api, widget.reference, agent: scope.config.agent);
    _notices = controller.notices.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
    unawaited(controller.start());
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final detail = controller.detail;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              child: Row(
                children: [
                  if (widget.onClose != null)
                    IconButton(tooltip: 'Close', icon: Icon(widget.closeIcon), onPressed: widget.onClose),
                  if (detail != null) ...[
                    Tooltip(
                      message: detail.item.type,
                      child: Icon(
                        ItemStyle.type(detail.item.type),
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(child: CopyableId(detail?.item.id ?? widget.reference, style: theme.textTheme.titleMedium)),
                  const Spacer(),
                  if (controller.busy)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  if (detail != null) ..._actions(controller, detail.item),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: switch ((detail, controller.error)) {
                (final ItemDetailDto detail, _) => _Detail(
                  controller: controller,
                  detail: detail,
                  onOpen: widget.onOpen,
                  openChildId: widget.openChildId,
                ),
                (null, final Object error) => Center(child: Text('$error')),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        );
      },
    );
  }

  List<Widget> _actions(ItemController controller, ItemDto item) => [
    if (!item.isDone && !item.isClaimed)
      TextButton.icon(
        onPressed: controller.busy ? null : controller.claim,
        icon: const Icon(Icons.pan_tool_outlined),
        label: const Text('Claim'),
      ),
    if (item.claim != null)
      TextButton.icon(
        onPressed: controller.busy ? null : controller.release,
        icon: const Icon(Icons.undo),
        label: const Text('Release'),
      ),
    if (!item.isDone) ...[
      const SizedBox(width: 4),
      FilledButton.icon(
        onPressed: controller.busy ? null : controller.complete,
        icon: const Icon(Icons.done),
        label: const Text('Done'),
      ),
    ],
  ];
}

class _Detail extends StatelessWidget {
  const _Detail({required this.controller, required this.detail, required this.onOpen, this.openChildId});

  final ItemController controller;
  final ItemDetailDto detail;
  final void Function(String id) onOpen;
  final String? openChildId;

  @override
  Widget build(BuildContext context) {
    final item = detail.item;
    final workflow = controller.workflow;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EditableTitle(title: item.title, onSave: (title) => controller.set('title', title)),
              const SizedBox(height: 4),
              Text(
                [
                  ?item.path,
                  if (item.created != null) 'created ${item.created}',
                  if (item.updated != null) 'updated ${item.updated}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (workflow != null) _Fields(controller: controller, item: item, workflow: workflow),
              const SizedBox(height: 12),
              _Status(item: item),
              _Labels(item: item, controller: controller),
              const SizedBox(height: 8),
              _Relations(detail: detail, controller: controller, onOpen: onOpen, openChildId: openChildId),
              if (item.extra.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final MapEntry(:key, :value) in item.extra.entries)
                  Text('$key: $value', style: theme.textTheme.bodySmall),
              ],
              const Divider(height: 32),
              _Body(body: item.body ?? '', onSave: controller.saveBody),
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
            final value = await _askText(context, 'Title', initial: title);
            if (value != null && value.trim().isNotEmpty && value != title) await onSave(value.trim());
          },
        ),
      ],
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
        final edited = await _askText(context, label, initial: value ?? '');
        if (edited != null && edited.trim() != (value ?? '')) await onSave(edited.trim());
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        child: Text(value ?? '—', overflow: TextOverflow.ellipsis),
      ),
    ),
  );
}

class _Status extends StatelessWidget {
  const _Status({required this.item});

  final ItemDto item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final claim = item.claim;
    final tags = [
      if (item.pr case final pr?) PrLink(pr),
      if (item.ready) Tag('ready to pick', icon: Icons.play_arrow, color: Colors.green.shade700),
      if (item.blocked) Tag('blocked by ${item.blockedBy.join(', ')}', icon: Icons.block, color: scheme.error),
      if (claim != null)
        Tag(
          '${claim.expired ? 'expired claim' : 'claimed'} by ${claim.agent} until ${_time(claim.expiresAt)}',
          icon: Icons.smart_toy_outlined,
          color: claim.expired ? scheme.outline : Colors.amber.shade800,
        ),
      if (!item.checklist.isEmpty) Tag('checklist ${item.checklist}', icon: Icons.checklist),
      if (!item.children.isEmpty) Tag('children ${item.children}', icon: Icons.account_tree_outlined),
    ];
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
          final label = await _askText(context, 'Add labels (comma separated)');
          if (label != null && label.trim().isNotEmpty) {
            await controller.change([ItemUpdateRequest.add('labels', label)]);
          }
        },
      ),
    ],
  );
}

/// Kinds of links of an item, each a foldable section with its count.
enum _Relation {
  children('Children'),
  parent('Parent', field: 'parent'),
  dependencies('Depends on', field: 'depends_on'),
  dependents('Blocks'),
  related('Related', field: 'related');

  const _Relation(this.title, {this.field});

  final String title;

  /// Front-matter field edited by adding and removing links; null for links
  /// that are derived from other items.
  final String? field;

  List<ItemLinkDto> of(ItemDetailDto detail) => switch (this) {
    children => detail.children,
    parent => [?detail.parent],
    dependencies => detail.dependencies,
    dependents => detail.dependents,
    related => detail.related,
  };
}

/// Links of the item as foldable sections ("Children (19) · 7/19 done");
/// empty ones are left out, and links are added from the row below them.
class _Relations extends StatefulWidget {
  const _Relations({required this.detail, required this.controller, required this.onOpen, this.openChildId});

  final ItemDetailDto detail;
  final ItemController controller;
  final void Function(String id) onOpen;
  final String? openChildId;

  @override
  State<_Relations> createState() => _RelationsState();
}

class _RelationsState extends State<_Relations> {
  final _folded = <_Relation>{};

  Future<void> _add(_Relation relation) async {
    final field = relation.field!;
    final id = (await _askText(context, '${relation.title} — item id'))?.trim();
    if (id == null || id.isEmpty) return;
    await widget.controller.change([
      field == 'parent' ? ItemUpdateRequest.set(field, id) : ItemUpdateRequest.add(field, id),
    ]);
  }

  Future<void> _remove(_Relation relation, ItemLinkDto link) => widget.controller.change([
    relation.field == 'parent'
        ? ItemUpdateRequest.set('parent', null)
        : ItemUpdateRequest.remove(relation.field!, link.id),
  ]);

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final addable = [
      for (final relation in _Relation.values)
        if (relation.field != null && !(relation == _Relation.parent && detail.parent != null)) relation,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final relation in _Relation.values)
          if (relation.of(detail) case final links when links.isNotEmpty) ...[
            InkWell(
              key: ValueKey('relation-${relation.name}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () =>
                  setState(() => _folded.contains(relation) ? _folded.remove(relation) : _folded.add(relation)),
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Row(
                  children: [
                    Icon(_folded.contains(relation) ? Icons.chevron_right : Icons.expand_more, size: 18),
                    const SizedBox(width: 2),
                    Text('${relation.title} (${links.length})', style: theme.textTheme.titleSmall),
                    if (relation == _Relation.children && !detail.item.children.isEmpty) ...[
                      const SizedBox(width: 8),
                      Text('${detail.item.children} done', style: muted),
                    ],
                  ],
                ),
              ),
            ),
            if (!_folded.contains(relation))
              for (final link in links)
                _LinkTile(
                  link: link,
                  selected: link.id == widget.openChildId,
                  onOpen: link.isMissing ? null : () => widget.onOpen(link.id),
                  onRemove: relation.field == null ? null : () => _remove(relation, link),
                ),
          ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Link:', style: muted),
              for (final relation in addable)
                TextButton.icon(
                  key: ValueKey('add-${relation.name}'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => _add(relation),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(relation.title),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link, this.onOpen, this.onRemove, this.selected = false});

  final ItemLinkDto link;

  /// Open in the next panel.
  final bool selected;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('link-${link.id}'),
      dense: true,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      leading: Icon(
        link.category == StatusCategoryDto.done ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: link.isMissing ? scheme.error : ItemStyle.category(link.category, scheme),
      ),
      title: Text(link.isMissing ? '${link.id} (missing)' : '${link.id}  ${link.title}'),
      subtitle: link.status == null ? null : Text(link.status!),
      onTap: onOpen,
      trailing: onRemove == null
          ? null
          : IconButton(tooltip: 'Remove', icon: const Icon(Icons.close, size: 16), onPressed: onRemove),
    );
  }
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

Future<String?> _askText(BuildContext context, String label, {String initial = ''}) {
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
