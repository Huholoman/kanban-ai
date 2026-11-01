import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/item_controller.dart';
import 'discussion_section.dart';

/// The item's activity under its description: tabs *Comments* (the
/// discussion with its reply field) and *History* (who changed what when).
class ActivitySection extends StatelessWidget {
  const ActivitySection({super.key, required this.controller});

  final ItemController controller;

  @override
  Widget build(BuildContext context) {
    final comments = controller.detail!.discussion.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedChoice<bool>(
            segments: [
              ChoiceSegment(
                value: false,
                label: comments == 0 ? 'Comments' : 'Comments · $comments',
                key: const ValueKey('tab-comments'),
              ),
              const ChoiceSegment(
                value: true,
                label: 'History',
                tooltip: 'Who changed what and when',
                key: ValueKey('tab-history'),
              ),
            ],
            selected: {controller.showHistory},
            onToggle: (history) => unawaited(controller.setShowHistory(history)),
          ),
        ),
        const SizedBox(height: 8),
        if (controller.showHistory)
          HistorySection(controller: controller)
        else
          DiscussionSection(controller: controller),
      ],
    );
  }
}

/// The item's history, newest first, with a filter: changes of fields and
/// the description (from the backlog's git history and the uncommitted
/// file), comments and agent runs; times relative, exact in the tooltip.
class HistorySection extends StatelessWidget {
  const HistorySection({super.key, required this.controller});

  final ItemController controller;

  static const _filters = {
    null: 'All',
    'status': 'Status',
    'fields': 'Changes',
    'comments': 'Comments',
    'runs': 'Agents',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final history = controller.history;
    return Container(
      key: const ValueKey('history'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedChoice<String?>(
              segments: [
                for (final MapEntry(:key, :value) in _filters.entries)
                  ChoiceSegment(value: key, label: value, key: ValueKey('history-filter-${key ?? 'all'}')),
              ],
              selected: {controller.historyFilter},
              onToggle: (only) => unawaited(controller.filterHistory(only)),
            ),
          ),
          if (controller.historyError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('$error', style: small?.copyWith(color: tokens.danger)),
            )
          else if (history == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Nothing yet.', style: small?.copyWith(color: tokens.muted)),
            )
          else
            for (final (index, entry) in history.reversed.indexed)
              _Entry(key: ValueKey('history-$index'), entry: entry),
        ],
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({super.key, required this.entry});

  final HistoryEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: tokens.muted);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(_icon(entry), size: 16, color: tokens.muted),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.author ?? 'someone',
                      style: small?.copyWith(color: tokens.text, fontWeight: FontWeight.w600),
                    ),
                    TimeText(entry.at, style: muted),
                    if (entry.uncommitted && entry.kind != 'comment' && entry.kind != 'run')
                      Tooltip(
                        message: 'In the file, not committed to the backlog repository yet',
                        child: Tag('uncommitted', color: tokens.muted),
                      ),
                    if (entry.commit case final commit?)
                      Text(commit.length > 7 ? commit.substring(0, 7) : commit, style: muted),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  describe(entry),
                  style: small?.copyWith(color: tokens.text),
                  maxLines: entry.kind == 'comment' ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(HistoryEntryDto entry) => switch (entry.kind) {
    'created' => Icons.add_circle_outline,
    'field' when entry.field == 'status' => Icons.swap_horiz,
    'field' when entry.field == 'checklist' => Icons.checklist,
    'field' => Icons.edit_outlined,
    'body' => Icons.notes,
    'comment' when entry.tag == 'question' => Icons.help_outline,
    'comment' when entry.tag?.startsWith('review') ?? false => Icons.rate_review_outlined,
    'comment' => Icons.chat_bubble_outline,
    'run' => Icons.smart_toy_outlined,
    _ => Icons.history,
  };
}

/// What [entry] says in one line: `status: todo → review`, `commented: …`.
String describe(HistoryEntryDto entry) {
  String text(String? value) => value ?? '–';
  return switch (entry.kind) {
    'created' => 'created the item${entry.after == null ? '' : ' (${entry.after})'}',
    'field' => '${entry.field}: ${text(entry.before)} → ${text(entry.after)}',
    'body' => 'edited the description',
    'comment' => '${entry.tag ?? 'commented'}: ${entry.text ?? ''}',
    'run' => '${entry.tag == null ? 'agent' : 'action ${entry.tag}'}: ${entry.text ?? ''}',
    _ => entry.kind,
  };
}
