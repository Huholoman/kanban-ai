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
    List<String>? types,
    this.onEnter,
    this.prompt,
    this.command,
    this.builtIn,
    this.agent,
    bool fresh = false,
    this.review = false,
    this.split = false,
    this.autoFix = 0,
    this.changesCode = false,
    this.then,
  }) : statuses = statuses == null ? null : List.unmodifiable(statuses),
       types = types == null ? null : List.unmodifiable(types),
       fresh = fresh || review || split {
    final label = 'dispatcher.actions "$name"';
    if (name.trim().isEmpty || name != name.trim()) {
      throw const ConfigurationException('dispatcher.actions[].name must not be empty or start/end with a space.');
    }
    if (name.contains('/')) throw ConfigurationException('$label: the name must not contain "/".');
    final kinds = [prompt, command, builtIn].nonNulls.length;
    if (review && split) throw ConfigurationException('$label: give review or split, not both.');
    if ((review || split) && (command != null || builtIn != null)) {
      throw ConfigurationException('$label: ${review ? 'a review' : 'a split'} runs an agent; it takes no run.');
    }
    if (!review && !split && kinds != 1) {
      throw ConfigurationException('$label: give exactly one of prompt, run, review and split.');
    }
    if (builtIn case final builtIn? when !builtIns.containsKey(builtIn)) {
      throw ConfigurationException(
        '$label: unknown built-in action "$builtIn" (known: ${builtIns.keys.join(', ')}); '
        'a command is a list, e.g. run: [sh, -c, "make test"].',
      );
    }
    if (autoFix < 0) throw ConfigurationException('$label: auto_fix must be 0 or more rounds.');
    if (autoFix > 0 && !review) throw ConfigurationException('$label: auto_fix only applies to a review.');
    if (then != null && !review) throw ConfigurationException('$label: then only applies to a review.');
    if (then != null && (onEnter == null || then == onEnter)) {
      throw ConfigurationException(
        '$label: then needs on_enter (the status the review runs in) and must name another status.',
      );
    }
    if (changesCode && (kind != ActionKind.prompt || review || split)) {
      throw ConfigurationException('$label: changes_code only applies to prompt actions (not to a review or split).');
    }
    if (kind != ActionKind.prompt && (agent != null || fresh)) {
      throw ConfigurationException('$label: agent and fresh only apply to prompt actions.');
    }
    if (statuses != null && statuses.toSet().length != statuses.length) {
      throw ConfigurationException('$label: statuses lists a status twice.');
    }
    if (types != null && types.toSet().length != types.length) {
      throw ConfigurationException('$label: types lists a type twice.');
    }
  }

  /// Actions built into kanban-ai, usable as `run: <name>`, with what they
  /// do. Each needs an implementation in the launcher's registry
  /// (`BuiltInActions`).
  static const builtIns = <String, String>{
    'noop': 'does nothing and succeeds (for trying actions out)',
    'merge': 'merges the item\'s branch into the base (dispatcher.merge), then marks it done and cleans up',
    'preview':
        'deploys the item\'s branch rebased onto the base locally and restarts the board from it '
        '(dispatcher.preview)',
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

  /// Types of items that offer the action as a button and run it as a hook;
  /// null means every type, or `epic` and `story` for a [split] ([splitTypes]).
  final List<String>? types;

  /// The types a [split] is offered for when it names none.
  static const splitTypes = ['epic', 'story'];

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
  /// that changes nothing and ends with `kanban-ai review`. Its runs show as
  /// the item's review state `running`.
  final bool review;

  /// An AI split (`split: true`): an agent in a new session with the
  /// built-in task ([splitTask]; [prompt], when given, adds to it) that
  /// proposes the tasks the item consists of as drafts under it
  /// (`kanban-ai new --draft --parent`), for a person to approve or discard.
  final bool split;

  /// For a [review]: when it asks for changes, the dispatcher wakes the
  /// item's agent to fix them and reviews again, at most this many rounds
  /// (0: never, the default).
  final int autoFix;

  /// A prompt action whose agent changes code (`changes_code: true`, e.g.
  /// fixing review comments): while it runs, an item handed over before
  /// (`review`) shows in the active status and goes back afterwards, like
  /// for the item's own agent. Other actions leave the status alone.
  final bool changesCode;

  /// For a [review] that runs [onEnter] a status of its own (`ai-review`):
  /// where the item goes on to when the review is over — after `ok` (or no
  /// verdict), and after `changes` that no automatic fix round takes up —
  /// typically `review`, where a person looks at it (`then: review`).
  final String? then;

  ActionKind get kind => prompt != null || review || split
      ? ActionKind.prompt
      : command != null
      ? ActionKind.command
      : ActionKind.builtIn;

  /// The task of a [review] agent for an item with the action prompt's
  /// [values] (`id`, `branch`, `base`, `pr`, …): review the branch against
  /// the base, change nothing, finish with `kanban-ai review`. [extra] (the
  /// rendered [prompt]) is added as further instructions.
  static String reviewTask(Map<String, String> values, {String? extra}) {
    const reviewFolder = DispatcherConfig.scratchFolder;
    final id = values['id']!, branch = values['branch']!, base = values['base']!;
    final pr = values['pr'] ?? '';
    return 'Review the work on backlog item $id: the changes of branch $branch against $base '
        '(`git log $base..$branch`, `git diff $base...$branch`)${pr.isEmpty ? '' : ', proposed as pull request $pr'}. '
        'Read the item\'s assignment and discussion (`kanban-ai show $id`) and the project\'s rules for contributors '
        'where the repository has them (CLAUDE.md, AGENTS.md, CONTRIBUTING.md, README.md). Check:\n'
        '1. correctness: does it do what the item asks; bugs, edge cases, error handling;\n'
        '2. tests: is the new behaviour tested, do the tests really check it; run the project\'s checks when its '
        'rules say how and they are quick;\n'
        '3. documentation: user documentation and specifications updated as the project\'s rules require;\n'
        '4. security: injection, secrets, unsafe defaults, destructive operations;\n'
        '5. scope: unrelated changes, needless complexity.\n'
        'Change nothing: no edits (except the review file below), no commits, no pushes, no changes to the item\'s '
        'fields or status. You approve nothing; a person decides and merges.\n'
        '${extra == null || extra.trim().isEmpty ? '' : '\nAlso: ${extra.trim()}\n'}'
        '\nFinish with exactly one of\n'
        '  kanban-ai review $id --ok "<what you checked, in one or two sentences>"\n'
        '  kanban-ai review $id --changes --file $reviewFolder/review-$id.md\n'
        'For --changes first write the review with your Write tool to $reviewFolder/review-$id.md in this worktree '
        '(git ignores $reviewFolder/): a one-line summary, a blank line, then the findings as a numbered list, one '
        'per line: 1. <file:line> – what is wrong and what to do. Keep every command on one line: a command with '
        'line breaks (a long text, a here-document) is denied and the review is lost. Only real problems are '
        'findings; leave out matters of taste. That review is your only comment on the item; write it in the '
        'language the people in the item use.';
  }

  /// The task of a [split] agent for an item with the action prompt's
  /// [values] (`id`, …): propose the tasks the item consists of as drafts
  /// under it, change nothing else. [extra] (the rendered [prompt]) is added
  /// as further instructions.
  static String splitTask(Map<String, String> values, {String? extra}) {
    const folder = DispatcherConfig.scratchFolder;
    final id = values['id']!;
    return 'Split backlog item $id into the tasks it consists of, as drafts for a person to approve. '
        'Read the item with its discussion (`kanban-ai show $id`), the items already under it '
        '(`kanban-ai list --all --where parent=$id`), the project\'s rules for contributors where the repository has '
        'them (CLAUDE.md, AGENTS.md, CONTRIBUTING.md, README.md) and the code the work will touch.\n'
        'Propose small tasks, each one change an agent can make and verify in one go, that together deliver the '
        'item and do not repeat the items already under it. Create each with\n'
        '  kanban-ai new "<short imperative title>" --draft --parent $id -t task -p <priority> '
        '--body-file $folder/split-$id-<n>.md [--depends-on <id of an earlier draft>] [--touches <paths>]\n'
        'writing its body first with your Write tool to $folder/split-$id-<n>.md in this worktree (git ignores '
        '$folder/): what to do and why, and an acceptance checklist (`- [ ] …` lines). Create them in the order '
        'they can be done, so that --depends-on names drafts created before; use it only for hard prerequisites. '
        'Do not give a milestone or status: a draft takes its parent\'s.\n'
        'Change nothing else: no edits (except those body files), no commits, no pushes, no changes to existing '
        'items. You approve nothing; a person approves or discards the drafts.'
        '${extra == null || extra.trim().isEmpty ? '' : '\n\nAlso: ${extra.trim()}'}';
  }

  /// Whether items in [status] (of [type], when given) show the action as
  /// a button.
  bool offeredIn(String status, {String? type}) =>
      (type == null || appliesTo(type)) &&
      switch (statuses) {
        final listed? => listed.contains(status),
        null => onEnter == null || onEnter == status,
      };

  /// Whether the action is for items of [type] ([types]).
  bool appliesTo(String type) => (types ?? (split ? splitTypes : null))?.contains(type) ?? true;

  /// One line for logs and lists: `prompt`, `run: sh -c …`, `run: merge`.
  String get summary => switch (kind) {
    ActionKind.prompt =>
      '${review ? 'AI review${autoFix > 0 ? ' (auto-fix $autoFix)' : ''}${then == null ? '' : ', then $then'}, ' : ''}${split ? 'AI split, ' : ''}agent${agent == null ? '' : ' $agent'}${fresh ? ', new session' : ''}${changesCode ? ', changes code' : ''}',
    ActionKind.command => 'run: $command',
    ActionKind.builtIn => 'run: $builtIn',
  };
}
