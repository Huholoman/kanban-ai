import 'package:collection/collection.dart';

import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../workflow/domain/dispatcher_config.dart';

/// The session of an agent's last run on an item, which a later start of the
/// same item can continue (`claude --resume <id>`).
final class AgentSession {
  const AgentSession({
    required this.item,
    required this.id,
    required this.worktree,
    required this.agent,
    required this.startedAt,
    this.endedAt,
    this.reason,
    this.outcome,
  });

  final ItemId item;

  /// The agent's own session id.
  final String id;

  /// The worktree it ran in; the agent keeps its sessions per folder, so it
  /// can only be continued there.
  final String worktree;

  /// Name of the agent profile that ran it.
  final String agent;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// How the run ended (`exited with code 0`, `was stopped by a person`, …).
  final String? reason;

  /// What happened to the item then (`it handed over as review, claim dropped`, …).
  final String? outcome;

  /// Whether [profile] can continue this session in [worktreeName].
  bool resumableBy(AgentProfile profile, String worktreeName) =>
      profile.canResume && profile.name == agent && worktree == worktreeName;

  /// Comments in [item]'s discussion written since this run started by
  /// someone other than the agent: what a person said to it meanwhile.
  /// Notes ([Comment.note]) are not replies: they do not wake the agent.
  List<Comment> repliesIn(Item item) => item.discussion.after(startedAt, except: worktree);

  /// The new comments of others since this run, notes included: what
  /// `{news}` shows a resumed agent.
  List<Comment> commentsIn(Item item) => item.discussion.after(startedAt, except: worktree, notes: true);

  /// What happened since this run, for the `{news}` of the resume prompt:
  /// how it ended and the new [comments] (see [commentsIn]); notes are
  /// marked as context that needs no answer.
  String news([List<Comment> comments = const []]) {
    final ended = [?reason, ?outcome].join('; ');
    final run = ended.isEmpty ? 'your last run ended.' : 'your last run $ended.';
    if (comments.isEmpty) return '$run No new comments in the discussion.';
    final listed = [for (final comment in comments) '${comment.heading}\n\n${comment.text}'].join('\n\n');
    final notes = comments.any((c) => c.note)
        ? 'Comments marked "note" are context for you; they need no answer.\n'
        : '';
    return '$run New comments in the item\'s discussion since then:\n\n$listed\n$notes';
  }
}

/// When and in which worktree the last run of an item's own agent started
/// (`<id>.last.json`), whether or not it reported a session.
typedef AgentStart = ({DateTime at, String worktree});

/// What others said to [item]'s agent that a new session has to take up
/// when no session can be continued: the comments since the agent's last
/// [start], except its own (notes and reviews only with [notes]). Without a
/// known start (the item was worked on elsewhere) only an [active] item
/// (in progress, in review, …) with a `branch` counts — an agent's work
/// exists — and the comments after the last one of its assignee. Once a
/// new session has started, these comments are older than its start and
/// wake nobody again.
List<Comment> repliesWithoutSession(Item item, AgentStart? start, {required bool active, bool notes = false}) {
  if (start != null) return item.discussion.after(start.at, except: start.worktree, notes: notes);
  if (!active || (item.branch?.trim().isEmpty ?? true)) return const [];
  final assignee = item.assignee;
  final last = assignee == null ? null : item.discussion.comments.lastWhereOrNull((c) => c.author == assignee);
  return item.discussion.after(last?.at ?? DateTime.utc(1970), except: assignee, notes: notes);
}

/// `{news}` of the resume prompt for a new session started because of
/// [comments] (see [repliesWithoutSession]): there is no earlier session
/// to continue, so the agent first gets its bearings.
String newSessionNews(List<Comment> comments) {
  const fresh =
      'there is no earlier session of yours to continue here (it ran elsewhere or is gone), so this is a new '
      'session: first run `backlog instructions`, read the item and look at the commits on its branch.';
  if (comments.isEmpty) return '$fresh No new comments in the discussion.';
  final listed = [for (final comment in comments) '${comment.heading}\n\n${comment.text}'].join('\n\n');
  final notes = comments.any((c) => c.isContext)
      ? 'Comments marked "note" or "review" are context for you; they need no answer.\n'
      : '';
  return '$fresh New comments in the item\'s discussion:\n\n$listed\n$notes';
}
