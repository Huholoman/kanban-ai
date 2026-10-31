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

  /// What happened since this run, for the `{news}` of the resume prompt.
  String news() {
    final ended = [?reason, ?outcome].join('; ');
    return ended.isEmpty ? 'your last run ended.' : 'your last run $ended.';
  }
}
