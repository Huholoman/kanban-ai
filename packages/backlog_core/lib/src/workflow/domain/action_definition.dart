import '../../shared/errors.dart';
import 'dispatcher_config.dart';

/// What an action does when it runs.
enum ActionKind {
  /// Starts an agent with the action's prompt (`prompt:`).
  prompt,

  /// Runs a command (`run: [program, args…]`).
  command,

  /// Runs an action built into kanban-ai (`run: <name>`, see
  /// [ActionDefinition.builtIns]).
  builtIn;

  /// The name used in the API (`prompt`, `command`, `builtin`).
  String get id => this == builtIn ? 'builtin' : name;
}

/// One entry of `dispatcher.actions`: a button on items in [statuses] and/or
/// a hook that runs by itself when an item enters the status [onEnter]. It
/// either starts an agent with a [prompt], runs a [command] or a [builtIn]
/// action.
final class ActionDefinition {
  ActionDefinition({
    required this.name,
    List<String>? statuses,
    this.onEnter,
    this.prompt,
    this.command,
    this.builtIn,
    this.agent,
    bool fresh = false,
    this.review = false,
    this.autoFix = 0,
  }) : statuses = statuses == null ? null : List.unmodifiable(statuses),
       fresh = fresh || review {
    final label = 'dispatcher.actions "$name"';
    if (name.trim().isEmpty || name != name.trim()) {
      throw const ConfigurationException('dispatcher.actions[].name must not be empty or start/end with a space.');
    }
    if (name.contains('/')) throw ConfigurationException('$label: the name must not contain "/".');
    final kinds = [prompt, command, builtIn].nonNulls.length;
    if (review && (command != null || builtIn != null)) {
      throw ConfigurationException('$label: a review runs an agent; it takes no run.');
    }
    if (!review && kinds != 1) throw ConfigurationException('$label: give exactly one of prompt, run and review.');
    if (builtIn case final builtIn? when !builtIns.containsKey(builtIn)) {
      throw ConfigurationException(
        '$label: unknown built-in action "$builtIn" (known: ${builtIns.keys.join(', ')}); '
        'a command is a list, e.g. run: [sh, -c, "make test"].',
      );
    }
    if (autoFix < 0) throw ConfigurationException('$label: auto_fix must be 0 or more rounds.');
    if (autoFix > 0 && !review) throw ConfigurationException('$label: auto_fix only applies to a review.');
    if (kind != ActionKind.prompt && (agent != null || fresh)) {
      throw ConfigurationException('$label: agent and fresh only apply to prompt actions.');
    }
    if (statuses != null && statuses.toSet().length != statuses.length) {
      throw ConfigurationException('$label: statuses lists a status twice.');
    }
  }

  /// Actions built into kanban-ai, usable as `run: <name>`, with what they
  /// do. Each needs an implementation in the launcher's registry
  /// (`BuiltInActions`).
  static const builtIns = <String, String>{
    'noop': 'does nothing and succeeds (for trying actions out)',
    'merge': 'merges the item\'s branch into the base (dispatcher.merge), then marks it done and cleans up',
  };

  /// What an action's prompt may refer to: the dispatcher prompt's
  /// placeholders, the item's `{pr}` and `{status}`, `dispatcher.base`, the
  /// action's `{action}` name and `{news}` (what happened since the item's
  /// last session when the agent continues it).
  static const promptPlaceholders = [...DispatcherConfig.promptPlaceholders, 'pr', 'status', 'base', 'action', 'news'];

  /// What an action's command may refer to. `{worktree}` and `{path}` are
  /// where it runs (`{worktree}` is empty in the primary clone).
  static const commandPlaceholders = [
    'id',
    'title',
    'branch',
    'pr',
    'status',
    'worktree',
    'path',
    'backlog',
    'base',
    'action',
  ];

  /// Unique within `dispatcher.actions`; the button's label and the name in
  /// the API and CLI.
  final String name;

  /// Statuses whose items offer the action as a button; null means every
  /// status, or only [onEnter] when that is set. Empty: never a button.
  final List<String>? statuses;

  /// The action runs by itself, once, whenever an item enters this status.
  final String? onEnter;

  /// The agent's task (with the placeholders of [promptPlaceholders]).
  final TextTemplate? prompt;

  /// The command to run (with the placeholders of [commandPlaceholders]).
  final CommandTemplate? command;

  /// The name of the built-in action to run ([builtIns]).
  final String? builtIn;

  /// The agent profile for a prompt action; null means `dispatcher.agent`.
  final String? agent;

  /// A prompt action starts a new agent session instead of continuing the
  /// item's last one; such a side session never becomes the item's session.
  /// Always true for a [review].
  final bool fresh;

  /// An AI review (`review: true`): an agent in a new session with the
  /// built-in review task ([reviewTask]; [prompt], when given, adds to it)
  /// that changes nothing and ends with `backlog review`. Its runs show as
  /// the item's review state `running`.
  final bool review;

  /// For a [review]: when it asks for changes, the dispatcher wakes the
  /// item's agent to fix them and reviews again, at most this many rounds
  /// (0: never, the default).
  final int autoFix;

  ActionKind get kind => prompt != null || review
      ? ActionKind.prompt
      : command != null
      ? ActionKind.command
      : ActionKind.builtIn;

  /// The task of a [review] agent for an item with the action prompt's
  /// [values] (`id`, `branch`, `base`, `pr`, …): review the branch against
  /// the base, change nothing, finish with `backlog review`. [extra] (the
  /// rendered [prompt]) is added as further instructions.
  static String reviewTask(Map<String, String> values, {String? extra}) {
    final id = values['id']!, branch = values['branch']!, base = values['base']!;
    final pr = values['pr'] ?? '';
    return 'Review the work on backlog item $id: the changes of branch $branch against $base '
        '(`git log $base..$branch`, `git diff $base...$branch`)${pr.isEmpty ? '' : ', proposed as pull request $pr'}. '
        'Read the item\'s assignment and discussion (`backlog show $id`) and the project\'s rules for contributors '
        'where the repository has them (CLAUDE.md, AGENTS.md, CONTRIBUTING.md, README.md). Check:\n'
        '1. correctness: does it do what the item asks; bugs, edge cases, error handling;\n'
        '2. tests: is the new behaviour tested, do the tests really check it; run the project\'s checks when its '
        'rules say how and they are quick;\n'
        '3. documentation: user documentation and specifications updated as the project\'s rules require;\n'
        '4. security: injection, secrets, unsafe defaults, destructive operations;\n'
        '5. scope: unrelated changes, needless complexity.\n'
        'Change nothing: no edits, no commits, no pushes, no changes to the item\'s fields or status. You approve '
        'nothing; a person decides and merges.\n'
        '${extra == null || extra.trim().isEmpty ? '' : '\nAlso: ${extra.trim()}\n'}'
        '\nFinish with exactly one of\n'
        '  backlog review $id --ok "<what you checked, in one or two sentences>"\n'
        '  backlog review $id --changes "<a one-line summary, a blank line, then the findings as a numbered list, '
        'one per line: 1. <file:line> – what is wrong and what to do>"\n'
        'The text may span several lines (or give - and pipe it in). Only real problems are findings; leave out '
        'matters of taste. That review is your only comment on the item; write it in the language the people in the '
        'item use.';
  }

  /// Whether items in [status] show the action as a button.
  bool offeredIn(String status) => switch (statuses) {
    final listed? => listed.contains(status),
    null => onEnter == null || onEnter == status,
  };

  /// One line for logs and lists: `prompt`, `run: sh -c …`, `run: merge`.
  String get summary => switch (kind) {
    ActionKind.prompt =>
      '${review ? 'AI review${autoFix > 0 ? ' (auto-fix $autoFix)' : ''}, ' : ''}agent${agent == null ? '' : ' $agent'}${fresh ? ', new session' : ''}',
    ActionKind.command => 'run: $command',
    ActionKind.builtIn => 'run: $builtIn',
  };
}
