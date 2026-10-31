import '../../shared/errors.dart';
import 'dispatcher_config.dart';

/// How the built-in action `merge` brings an item's branch into
/// `dispatcher.base`.
enum MergeStrategy {
  /// Merges the item's pull request with `dispatcher.pr.merge` (tea, gh).
  pr,

  /// Rebases the branch onto the base, runs `check`, fast-forwards the base
  /// in the primary clone and optionally pushes it.
  local,

  /// Runs an own command (`dispatcher.merge.command`).
  command;

  static MergeStrategy parse(String value) => values.firstWhere(
    (strategy) => strategy.name == value,
    orElse: () => throw ConfigurationException('dispatcher.merge.strategy must be pr, local or command, got "$value".'),
  );
}

/// `dispatcher.merge`: how the built-in action `merge` (typically
/// `on_enter: deploy`) merges an item's branch, and whether it cleans up
/// after itself.
final class MergeConfig {
  MergeConfig({
    required this.strategy,
    this.check,
    this.push = false,
    this.remote = 'origin',
    this.command,
    this.cleanup = true,
  }) {
    if (strategy == MergeStrategy.command && command == null) {
      throw const ConfigurationException('dispatcher.merge: strategy command needs dispatcher.merge.command.');
    }
    if (strategy != MergeStrategy.command && command != null) {
      throw ConfigurationException(
        'dispatcher.merge.command only applies to strategy command (the strategy is ${strategy.name}).',
      );
    }
    if (strategy != MergeStrategy.local && (check != null || push)) {
      throw ConfigurationException(
        'dispatcher.merge.check and push only apply to strategy local (the strategy is ${strategy.name}).',
      );
    }
    if (remote.isEmpty || remote.startsWith('-') || remote.contains(RegExp(r'\s'))) {
      throw ConfigurationException('dispatcher.merge.remote "$remote" is not a remote name.');
    }
  }

  /// What `check` and `command` may refer to: the item, its branch and pull
  /// request (`{pr}` = URL, `{pr_number}` = its number), the base and
  /// remote, where it runs (`{worktree}`, `{path}`) and the backlog folder.
  static const placeholders = [
    'id',
    'title',
    'branch',
    'base',
    'remote',
    'pr',
    'pr_number',
    'worktree',
    'path',
    'backlog',
  ];

  final MergeStrategy strategy;

  /// `local`: runs after the rebase, where the branch is checked out; the
  /// merge stops when it fails (e.g. `mise run check`).
  final CommandTemplate? check;

  /// `local`: pushes the merged base to [remote] (before the primary clone
  /// is fast-forwarded, never forced).
  final bool push;

  /// Where `local` pushes, and whose remote-tracking branches tell what was
  /// pushed (default `dispatcher.pr.remote`, else `origin`).
  final String remote;

  /// `command`: merges by itself; exit code 0 means merged.
  final CommandTemplate? command;

  /// After a merge: remove the item's branch, its created worktree (a listed
  /// one only goes back to the base, detached) and its agent session.
  final bool cleanup;
}
