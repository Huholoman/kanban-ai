import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/copyable_id.dart';
import '../../../shared/tokens.dart';
import '../application/item_controller.dart';

/// Top of the detail: back, the breadcrumb of parents and close; the item's
/// place among its siblings with ‹ › arrows; its id and the claim actions.
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onSibling,
    this.onBack,
    this.onClose,
    this.closeIcon = Icons.close,
    this.onScope,
  });

  final ItemController controller;

  /// Goes to an ancestor from the breadcrumb.
  final ValueChanged<String> onOpen;

  /// Steps to the previous or next sibling.
  final ValueChanged<String> onSibling;

  /// Null when there is no history to go back to.
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final IconData closeIcon;

  /// Scopes the board to an epic, see [ItemDetailView.onScope].
  final void Function(String epicId)? onScope;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final item = controller.item;
    final position = controller.position;
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (onBack != null) ...[
                SizedBox.square(
                  dimension: 28,
                  child: IconButton.outlined(
                    key: const ValueKey('detail-back'),
                    tooltip: 'Back',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    style: IconButton.styleFrom(
                      side: BorderSide(color: tokens.borderStrong),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(BoardTokens.radiusSmall)),
                    ),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: _Breadcrumb(controller: controller, onOpen: onOpen),
              ),
              if (controller.busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (onClose != null) IconButton(tooltip: 'Close', icon: Icon(closeIcon, size: 20), onPressed: onClose),
            ],
          ),
          if (item != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    position == null
                        ? '${_capitalized(item.type)} · ${item.id}'
                        : '${_capitalized(item.type)} ${position.index + 1} of ${position.count}',
                    style: small,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (position != null)
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.borderStrong),
                      borderRadius: BorderRadius.circular(BoardTokens.radius),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Arrow(
                          key: const ValueKey('sibling-previous'),
                          tooltip: 'Previous sibling',
                          icon: Icons.chevron_left,
                          target: position.previous,
                          onSibling: onSibling,
                        ),
                        Text('$position', key: const ValueKey('sibling-position'), style: small),
                        _Arrow(
                          key: const ValueKey('sibling-next'),
                          tooltip: 'Next sibling',
                          icon: Icons.chevron_right,
                          target: position.next,
                          onSibling: onSibling,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Flexible(child: CopyableId(item.id, style: small)),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: _actions(item)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _actions(ItemDto item) {
    final enabled = !controller.busy;
    return [
      if (onScope case final onScope? when item.type == 'epic')
        OutlinedButton.icon(
          key: const ValueKey('scope-board'),
          onPressed: () => onScope(item.id),
          icon: const Icon(Icons.filter_alt_outlined, size: 16),
          label: const Text('Scope board'),
        ),
      if (item.claim != null)
        OutlinedButton(onPressed: enabled ? controller.release : null, child: const Text('Release')),
      if (!item.isDone && !item.isClaimed)
        FilledButton(onPressed: enabled ? controller.claim : null, child: const Text('Claim')),
      if (!item.isDone)
        item.isClaimed
            ? FilledButton(onPressed: enabled ? controller.complete : null, child: const Text('Done'))
            : OutlinedButton(onPressed: enabled ? controller.complete : null, child: const Text('Done')),
    ];
  }

  static String _capitalized(String text) => text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
}

/// `Epic › Story › X-2c91 Title`; the ancestors lead to their detail.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.controller, required this.onOpen});

  final ItemController controller;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    final item = controller.item;
    return Row(
      children: [
        for (final ancestor in controller.ancestors) ...[
          Flexible(
            child: InkWell(
              key: ValueKey('ancestor-${ancestor.item.id}'),
              borderRadius: BorderRadius.circular(4),
              onTap: () => onOpen(ancestor.item.id),
              child: Tooltip(
                message: ancestor.item.id,
                child: Text(ancestor.item.title, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('›', style: style),
          ),
        ],
        Flexible(
          flex: 2,
          child: Text(
            item == null ? controller.reference : '${item.id} ${item.title}',
            style: style?.copyWith(color: tokens.text, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({super.key, required this.tooltip, required this.icon, required this.target, required this.onSibling});

  final String tooltip;
  final IconData icon;

  /// The sibling it leads to; null disables it.
  final String? target;
  final ValueChanged<String> onSibling;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 28,
    height: 26,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: Icon(icon),
      onPressed: switch (target) {
        final target? => () => onSibling(target),
        null => null,
      },
    ),
  );
}
