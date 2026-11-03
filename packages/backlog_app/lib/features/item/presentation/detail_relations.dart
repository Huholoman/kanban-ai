import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/item_body.dart';
import '../application/item_controller.dart';
import 'ask_text.dart';

/// The item's children ("Tasks 1 of 3 done"), each expandable in place to a
/// preview — the first lines of its body and its own children — with a
/// button that opens it in the panel. Children in two or more milestones get
/// a chip per milestone and *All* above them ([ItemController.childMilestone];
/// *Implement epic* starts with that scope).
class DetailChildren extends StatefulWidget {
  const DetailChildren({super.key, required this.controller, required this.onOpen});

  final ItemController controller;

  /// Navigates the panel to an item.
  final ValueChanged<String> onOpen;

  @override
  State<DetailChildren> createState() => _DetailChildrenState();
}

class _DetailChildrenState extends State<DetailChildren> {
  bool _folded = false;
  final _expanded = <String>{};

  void _toggle(String id) {
    setState(() => _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id));
    if (_expanded.contains(id) && widget.controller.preview(id) == null) {
      unawaited(widget.controller.loadPreview(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final detail = controller.detail!;
    final planned = controller.plannedChildren;
    if (planned.isEmpty) return const SizedBox.shrink();
    final children = controller.shownChildren;
    final milestones = controller.childMilestones;
    final hidden = planned.length - children.length;
    final tokens = BoardTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          key: const ValueKey('relation-children'),
          title: detail.item.type == 'story' ? 'Tasks' : 'Children',
          summary:
              '${_done(children)} of ${children.length} done${hidden == 0 ? '' : ' · $hidden in other milestones'}',
          folded: _folded,
          onTap: () => setState(() => _folded = !_folded),
        ),
        if (!_folded && milestones.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Wrap(
              key: const ValueKey('children-milestones'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final milestone in [...milestones, null])
                  ChoiceChip(
                    key: ValueKey('children-milestone-${milestone ?? 'all'}'),
                    label: Text(milestone ?? 'All'),
                    tooltip: milestone == null
                        ? 'All children'
                        : 'The children of $milestone and those without a milestone; Implement epic starts with it',
                    visualDensity: VisualDensity.compact,
                    selected: controller.childMilestone == milestone,
                    onSelected: (_) => controller.filterChildren(milestone),
                  ),
              ],
            ),
          ),
        if (!_folded && children.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: tokens.border),
              borderRadius: BorderRadius.circular(BoardTokens.radius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, child) in children.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  _ChildRow(
                    link: child,
                    expanded: _expanded.contains(child.id),
                    onToggle: child.isMissing ? null : () => _toggle(child.id),
                  ),
                  if (_expanded.contains(child.id))
                    _ChildPreview(id: child.id, detail: widget.controller.preview(child.id), onOpen: widget.onOpen),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The drafts among the item's children ("Proposed tasks", e.g. from an AI
/// split), each with what it comes after and buttons to approve or discard
/// it, and both for all of them at once.
class DetailDrafts extends StatelessWidget {
  const DetailDrafts({super.key, required this.controller, required this.onOpen});

  final ItemController controller;

  /// Navigates the panel to an item.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final drafts = controller.drafts;
    if (drafts.isEmpty) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.muted);
    final enabled = !controller.busy;
    return Column(
      key: const ValueKey('drafts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Proposed tasks',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${drafts.length} draft${drafts.length == 1 ? '' : 's'}', style: small),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('Nothing is planned until you approve them; discarded ones are deleted.', style: small),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.border),
            borderRadius: BorderRadius.circular(BoardTokens.radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, draft) in drafts.indexed) ...[
                if (index > 0) const Divider(height: 1),
                InkWell(
                  key: ValueKey('draft-${draft.id}'),
                  onTap: () => onOpen(draft.id),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinkLabel(link: draft),
                              if (draft.dependsOn.isNotEmpty) Text('after ${draft.dependsOn.join(', ')}', style: small),
                            ],
                          ),
                        ),
                        IconButton(
                          key: ValueKey('approve-${draft.id}'),
                          tooltip: 'Approve ${draft.id}',
                          iconSize: 18,
                          color: tokens.success,
                          icon: const Icon(Icons.check),
                          onPressed: enabled ? () => unawaited(controller.approveDrafts([draft.id])) : null,
                        ),
                        IconButton(
                          key: ValueKey('discard-${draft.id}'),
                          tooltip: 'Discard ${draft.id}',
                          iconSize: 18,
                          color: tokens.danger,
                          icon: const Icon(Icons.close),
                          onPressed: enabled ? () => unawaited(_discard(context, [draft])) : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            PrimaryButton(
              key: const ValueKey('approve-drafts'),
              label: drafts.length == 1 ? 'Approve' : 'Approve all',
              icon: Icons.check,
              onPressed: enabled ? () => unawaited(controller.approveDrafts()) : null,
            ),
            SecondaryButton(
              key: const ValueKey('discard-drafts'),
              label: drafts.length == 1 ? 'Discard' : 'Discard all',
              icon: Icons.close,
              onPressed: enabled ? () => unawaited(_discard(context, drafts)) : null,
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Discards [drafts] after a confirmation: their files are deleted.
  Future<void> _discard(BuildContext context, List<ItemLinkDto> drafts) async {
    final one = drafts.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(one ? 'Discard ${drafts.single.id}?' : 'Discard ${drafts.length} drafts?'),
        content: Text(
          '${one ? 'The draft is' : 'The drafts are'} deleted with ${one ? 'its' : 'their'} attachments; '
          'this cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('discard-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.discardDrafts([for (final draft in drafts) draft.id]);
  }
}

int _done(List<ItemLinkDto> links) => links.where((link) => link.category == StatusCategoryDto.done).length;

/// `▸ X-b18e  Script the restore  done`; a tap expands it.
class _ChildRow extends StatelessWidget {
  const _ChildRow({required this.link, required this.expanded, this.onToggle});

  final ItemLinkDto link;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Material(
      color: expanded ? tokens.page : Colors.transparent,
      child: InkWell(
        key: ValueKey('link-${link.id}'),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 28,
                child: IconButton(
                  key: ValueKey('expand-${link.id}'),
                  tooltip: '${expanded ? 'Collapse' : 'Expand'} ${link.id}',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  color: tokens.muted,
                  icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
                  onPressed: onToggle,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(child: LinkLabel(link: link)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Id, title and status of a linked item on one line.
class LinkLabel extends StatelessWidget {
  const LinkLabel({super.key, required this.link});

  final ItemLinkDto link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BoardTokens.of(context);
    final small = theme.textTheme.bodySmall;
    return Row(
      children: [
        Text(link.id, style: small),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            link.title ?? '(missing)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: link.isMissing ? TextStyle(color: tokens.danger) : null,
          ),
        ),
        if (link.status case final status?) ...[
          const SizedBox(width: 8),
          Text(
            status,
            style: small?.copyWith(
              color: link.category == StatusCategoryDto.done
                  ? tokens.success
                  : link.category == StatusCategoryDto.active
                  ? ItemStyle.category(link.category, theme.colorScheme)
                  : tokens.muted,
            ),
          ),
        ],
      ],
    );
  }
}

/// What an expanded child shows: its body excerpt, its own children and a
/// button that opens it.
class _ChildPreview extends StatelessWidget {
  const _ChildPreview({required this.id, required this.detail, required this.onOpen});

  final String id;

  /// Null while loading.
  final ItemDetailDto? detail;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    final detail = this.detail;
    final text = detail == null ? '' : excerpt(detail.item.body ?? '');
    return Container(
      margin: const EdgeInsets.fromLTRB(40, 0, 12, 10),
      padding: const EdgeInsets.only(left: 12, top: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: tokens.border, width: 2)),
      ),
      child: detail == null
          ? const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (text.isNotEmpty) Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
                if (detail.children.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Subtasks ${_done(detail.children)} of ${detail.children.length} done',
                    style: theme.textTheme.bodySmall,
                  ),
                  for (final child in detail.children)
                    InkWell(
                      key: ValueKey('sublink-${child.id}'),
                      onTap: child.isMissing ? null : () => onOpen(child.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: LinkLabel(link: child),
                      ),
                    ),
                ],
                LinkButton(
                  key: ValueKey('open-$id'),
                  label: 'Open $id →',
                  accent: true,
                  compact: true,
                  onPressed: () => onOpen(id),
                ),
              ],
            ),
    );
  }
}

/// Kinds of links of an item besides its children, each a foldable row.
enum _Relation {
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
    parent => [?detail.parent],
    dependencies => detail.dependencies,
    dependents => detail.dependents,
    related => detail.related,
  };
}

/// Parent, Depends on, Blocks and Related as folded rows with counts
/// ("Depends on 1 ▸"); empty ones are left out. A linked item opens in the
/// panel; links are added from the *Link:* row and removed with ×.
class DetailRelations extends StatefulWidget {
  const DetailRelations({super.key, required this.controller, required this.onOpen});

  final ItemController controller;

  /// Navigates the panel to an item.
  final ValueChanged<String> onOpen;

  @override
  State<DetailRelations> createState() => _DetailRelationsState();
}

class _DetailRelationsState extends State<DetailRelations> {
  final _unfolded = <_Relation>{};

  Future<void> _add(_Relation relation) async {
    final field = relation.field!;
    final id = (await askText(context, '${relation.title} — item id'))?.trim();
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
    final detail = widget.controller.detail!;
    final muted = Theme.of(context).textTheme.bodySmall;
    final addable = [
      for (final relation in _Relation.values)
        if (relation.field != null && !(relation == _Relation.parent && detail.parent != null)) relation,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final relation in _Relation.values)
          if (relation.of(detail) case final links when links.isNotEmpty) ...[
            _SectionHeader(
              key: ValueKey('relation-${relation.name}'),
              title: relation.title,
              summary: '${links.length}',
              folded: !_unfolded.contains(relation),
              onTap: () =>
                  setState(() => _unfolded.contains(relation) ? _unfolded.remove(relation) : _unfolded.add(relation)),
            ),
            if (_unfolded.contains(relation))
              for (final link in links)
                _LinkTile(
                  link: link,
                  onOpen: link.isMissing ? null : () => widget.onOpen(link.id),
                  onRemove: relation.field == null ? null : () => _remove(relation, link),
                ),
          ],
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Link:', style: muted),
              for (final relation in addable)
                LinkButton(
                  key: ValueKey('add-${relation.name}'),
                  label: relation.title,
                  icon: Icons.add,
                  accent: true,
                  compact: true,
                  onPressed: () => _add(relation),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A foldable row: the title left, a summary and the fold arrow right.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.title,
    required this.summary,
    required this.folded,
    required this.onTap,
  });

  final String title;
  final String summary;
  final bool folded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BoardTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.border)),
        ),
        child: Row(
          children: [
            Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 4),
            Icon(folded ? Icons.chevron_right : Icons.expand_more, size: 18, color: tokens.muted),
          ],
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link, this.onOpen, this.onRemove});

  final ItemLinkDto link;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('link-${link.id}'),
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            Expanded(child: LinkLabel(link: link)),
            if (onRemove != null)
              IconButton(
                tooltip: 'Remove',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    ),
  );
}
