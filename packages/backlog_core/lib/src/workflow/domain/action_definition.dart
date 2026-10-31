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
    this.fresh = false,
  }) : statuses = statuses == null ? null : List.unmodifiable(statuses) {
    final label = 'dispatcher.actions "$name"';
    if (name.trim().isEmpty || name != name.trim()) {
      throw const ConfigurationException('dispatcher.actions[].name must not be empty or start/end with a space.');
    }
    if (name.contains('/')) throw ConfigurationException('$label: the name must not contain "/".');
    final kinds = [prompt, command, builtIn].nonNulls.length;
    if (kinds != 1) throw ConfigurationException('$label: give exactly one of prompt and run.');
    if (builtIn case final builtIn? when !builtIns.containsKey(builtIn)) {
      throw ConfigurationException(
        '$label: unknown built-in action "$builtIn" (known: ${builtIns.keys.join(', ')}); '
        'a command is a list, e.g. run: [sh, -c, "make test"].',
      );
    }
    if (prompt == null && (agent != null || fresh)) {
      throw ConfigurationException('$label: agent and fresh only apply to prompt actions.');
    }
    if (statuses != null && statuses.toSet().length != statuses.length) {
      throw ConfigurationException('$label: statuses lists a status twice.');
    }
  }

  /// Actions built into kanban-ai, usable as `run: <name>`, with what they
  /// do. Each needs an implementation in the launcher's registry
  /// (`BuiltInActions`).
  static const builtIns = <String, String>{'noop': 'does nothing and succeeds (for trying actions out)'};

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
  final bool fresh;

  ActionKind get kind => prompt != null
      ? ActionKind.prompt
      : command != null
      ? ActionKind.command
      : ActionKind.builtIn;

  /// Whether items in [status] show the action as a button.
  bool offeredIn(String status) => switch (statuses) {
    final listed? => listed.contains(status),
    null => onEnter == null || onEnter == status,
  };

  /// One line for logs and lists: `prompt`, `run: sh -c …`, `run: merge`.
  String get summary => switch (kind) {
    ActionKind.prompt => 'agent${agent == null ? '' : ' $agent'}${fresh ? ', new session' : ''}',
    ActionKind.command => 'run: $command',
    ActionKind.builtIn => 'run: $builtIn',
  };
}
