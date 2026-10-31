import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../shared/item_style.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../../dispatch/presentation/dispatch_scope.dart';
import '../application/item_controller.dart';

/// The item's discussion (the `## Discussion` section of its body): the
/// comments of agents and people, an open question highlighted, and a field
/// for a reply. With a dispatcher that can continue the item's last agent
/// session, *Send* also wakes the agent: the dispatcher resumes it with the
/// reply by itself, in either mode. *Note only* (when there
/// is an agent session or an open question) saves a note that neither wakes
/// the agent nor answers the question; a resumed agent sees it as context.
class DiscussionSection extends StatefulWidget {
  const DiscussionSection({super.key, required this.controller});

  final ItemController controller;

  @override
  State<DiscussionSection> createState() => _DiscussionSectionState();
}

class _DiscussionSectionState extends State<DiscussionSection> {
  final _reply = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reply.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send({bool note = false}) async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    if (!await widget.controller.comment(text, note: note)) return;
    _reply.clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final detail = controller.detail!;
    final item = detail.item;
    final tokens = BoardTokens.of(context);
    final theme = Theme.of(context);
    final comments = detail.discussion;
    final open = item.needsHuman ? comments.lastWhere((c) => c.question, orElse: () => comments.last) : null;
    final dispatch = DispatchScope.maybeOf(context);
    final session = dispatch?.plan.sessionFor(item.id);
    final running = dispatch?.runFor(item.id) != null;
    final resumable = dispatch != null && session != null && !running && !item.isDone;
    final canSend = !controller.busy && _reply.text.trim().isNotEmpty;
    return Container(
      key: const ValueKey('discussion'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: open != null ? tokens.warning : tokens.border),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(comments.isEmpty ? 'Discussion' : 'Discussion · ${comments.length}', style: theme.textTheme.bodySmall),
          for (final comment in comments)
            _Comment(key: ValueKey('comment-${comment.at.toIso8601String()}'), comment: comment, open: comment == open),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('reply-field'),
            controller: _reply,
            minLines: 2,
            maxLines: 8,
            enabled: !controller.busy,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: open != null
                  ? 'Answer ${open.author}…'
                  : resumable
                  ? 'Write to the agent of ${item.id}…'
                  : 'Add a comment…',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (resumable)
                Text(
                  'Send: the agent continues in ${session.worktree} by itself. Note only: it is not woken.',
                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
                ),
              if (resumable || open != null)
                Tooltip(
                  message: [
                    'Saves a note: ',
                    if (resumable) 'the agent is not woken (it sees the note when it next continues)',
                    if (resumable && open != null) ' and ',
                    if (open != null) 'the question of ${open.author} stays open',
                  ].join(),
                  child: SecondaryButton(
                    key: const ValueKey('note-only'),
                    label: 'Note only',
                    icon: Icons.sticky_note_2_outlined,
                    onPressed: canSend ? () => unawaited(_send(note: true)) : null,
                  ),
                ),
              PrimaryButton(
                key: const ValueKey('send-comment'),
                label: 'Send',
                icon: Icons.send,
                onPressed: canSend ? () => unawaited(_send()) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Comment extends StatelessWidget {
  const _Comment({super.key, required this.comment, required this.open});

  final CommentDto comment;

  /// The question waits for an answer.
  final bool open;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final local = comment.at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                comment.author,
                style: small?.copyWith(color: tokens.text, fontWeight: FontWeight.w600),
              ),
              Text(
                '${local.day}.${local.month}. ${two(local.hour)}:${two(local.minute)}',
                style: small?.copyWith(color: tokens.muted),
              ),
              if (comment.note) Tag('note', icon: Icons.sticky_note_2_outlined, color: tokens.muted),
              if (comment.review case final review?)
                Tag(
                  review == 'ok'
                      ? 'review ✓'
                      : comment.findings == 0
                      ? 'review: changes'
                      : 'review: ${comment.findings} finding${comment.findings == 1 ? '' : 's'}',
                  icon: Icons.rate_review_outlined,
                  color: review == 'ok' ? tokens.success : tokens.warning,
                ),
              if (comment.commit case final commit?)
                Tooltip(
                  message: 'The reviewed commit',
                  child: Text(
                    commit.length > 7 ? commit.substring(0, 7) : commit,
                    style: small?.copyWith(color: tokens.muted),
                  ),
                ),
              if (comment.question)
                Tag(
                  open ? 'question · waits for you' : 'question',
                  icon: Icons.help_outline,
                  color: open ? tokens.warning : tokens.muted,
                ),
            ],
          ),
          const SizedBox(height: 2),
          MarkdownBody(data: comment.text, selectable: true),
        ],
      ),
    );
  }
}
