import 'package:yaml/yaml.dart';

import '../../shared/errors.dart';
import '../domain/action_definition.dart';
import '../domain/appearance.dart';
import '../domain/dispatcher_config.dart';
import '../domain/merge_config.dart';
import '../domain/workflow.dart';

/// Parses the `backlog.yaml` format into a [Workflow].
///
/// Every section is optional; missing ones fall back to [Workflow.standard].
Workflow parseWorkflowYaml(String source, {String origin = 'backlog.yaml'}) {
  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException('$origin: ${e.message}');
  }
  if (document == null) return Workflow.standard();
  if (document is! YamlMap) {
    throw ConfigurationException('$origin: expected a mapping at the top level.');
  }

  final standard = Workflow.standard();
  final id = _map(document['id'], 'id', origin);
  final defaults = _map(document['defaults'], 'defaults', origin);
  final claims = _map(document['claims'], 'claims', origin);

  final statusNodes = document['statuses'];
  final statuses = statusNodes == null
      ? standard.statuses
      : _list(statusNodes, 'statuses', origin).map((node) {
          final status = _map(node, 'statuses[]', origin);
          return StatusDefinition(
            _string(status['id'], 'statuses[].id', origin),
            StatusCategory.parse(_string(status['category'], 'statuses[].category', origin)),
            pickable: status['pickable'] == true,
          );
        }).toList();

  final milestones = _list(document['milestones'] ?? const [], 'milestones', origin).map((node) {
    if (node is! YamlMap) {
      return MilestoneDefinition(_string(node, 'milestones[]', origin));
    }
    return MilestoneDefinition(
      _string(node['id'], 'milestones[].id', origin),
      title: node['title']?.toString(),
      due: node['due']?.toString(),
    );
  }).toList();

  final leaseMinutes = claims['lease_minutes'];
  if (leaseMinutes != null && leaseMinutes is! int) {
    throw ConfigurationException('$origin: claims.lease_minutes must be an integer.');
  }
  final idLength = id['length'];
  if (idLength != null && idLength is! int) {
    throw ConfigurationException('$origin: id.length must be an integer.');
  }

  return Workflow(
    statuses: statuses,
    priorities: document['priorities'] == null
        ? standard.priorities
        : _strings(document['priorities'], 'priorities', origin),
    types: document['types'] == null ? standard.types : _strings(document['types'], 'types', origin),
    milestones: milestones,
    idPrefix: id['prefix']?.toString() ?? standard.idPrefix,
    idLength: (idLength as int?) ?? standard.idLength,
    defaultStatus: defaults['status']?.toString() ?? (statusNodes == null ? standard.defaultStatus : null),
    defaultPriority:
        defaults['priority']?.toString() ?? (document['priorities'] == null ? standard.defaultPriority : null),
    defaultType: defaults['type']?.toString() ?? (document['types'] == null ? standard.defaultType : null),
    claimLease: leaseMinutes == null ? standard.claimLease : Duration(minutes: leaseMinutes as int),
    appearance: _appearance(document['appearance'], origin),
    dispatcher: _dispatcher(document['dispatcher'], origin),
  );
}

DispatcherConfig? _dispatcher(Object? node, String origin) {
  if (node == null) return null;
  final yaml = _map(node, 'dispatcher', origin);
  const known = {
    'mode',
    'max_agents',
    'worktrees',
    'repo',
    'worktree_name',
    'max_worktrees',
    'cleanup_after_days',
    'base',
    'agent',
    'agents',
    'prompt',
    'resume_prompt',
    'command',
    'actions',
    'pr',
    'merge',
  };
  for (final key in yaml.keys) {
    if (!known.contains('$key')) {
      throw ConfigurationException('$origin: unknown key "dispatcher.$key" (expected ${known.join(', ')}).');
    }
  }
  try {
    final maxAgents = yaml['max_agents'];
    if (maxAgents != null && maxAgents is! int) {
      throw const ConfigurationException('dispatcher.max_agents must be an integer.');
    }
    final worktrees = yaml['worktrees'];
    final newWorktrees = _newWorktrees(yaml, origin);
    if (worktrees == null && newWorktrees == null) {
      throw const ConfigurationException('dispatcher.worktrees (or dispatcher.repo) is required.');
    }
    final prompt = yaml['prompt'];
    final resumePrompt = yaml['resume_prompt'];
    final pr = _pullRequest(yaml['pr'], origin);
    return DispatcherConfig(
      mode: DispatchMode.parse('${yaml['mode'] ?? 'manual'}'.trim()),
      maxAgents: maxAgents as int?,
      newWorktrees: newWorktrees,
      base: yaml['base'] == null ? 'main' : _base(_string(yaml['base'], 'dispatcher.base', origin)),
      agent: _agent(yaml, origin),
      profiles: _profiles(yaml, origin),
      actions: [
        for (final entry in _list(yaml['actions'] ?? const [], 'dispatcher.actions', origin)) _action(entry, origin),
      ],
      pr: pr,
      merge: _merge(yaml['merge'], pr, origin),
      prompt: prompt == null
          ? null
          : TextTemplate(
              _string(prompt, 'dispatcher.prompt', origin),
              known: DispatcherConfig.promptPlaceholders,
              label: 'dispatcher.prompt',
            ),
      resumePrompt: resumePrompt == null
          ? null
          : TextTemplate(
              _string(resumePrompt, 'dispatcher.resume_prompt', origin),
              known: DispatcherConfig.resumePromptPlaceholders,
              label: 'dispatcher.resume_prompt',
            ),
      worktrees: [
        if (worktrees != null)
          for (final entry in _list(worktrees, 'dispatcher.worktrees', origin))
            if (entry is Map)
              WorktreeDefinition(
                _string(entry['name'], 'dispatcher.worktrees[].name', origin),
                _string(entry['path'] ?? '../${entry['name']}', 'dispatcher.worktrees[].path', origin),
              )
            else
              WorktreeDefinition(
                _string(entry, 'dispatcher.worktrees[]', origin),
                '../${_string(entry, 'dispatcher.worktrees[]', origin)}',
              ),
      ],
    );
  } on ConfigurationException catch (e) {
    if (e.message.startsWith(origin)) rethrow;
    throw ConfigurationException('$origin: ${e.message}');
  }
}

/// `dispatcher.repo` with `worktree_name`, `max_worktrees` (default
/// `max_agents`) and `cleanup_after_days`; null without `repo`.
NewWorktrees? _newWorktrees(YamlMap yaml, String origin) {
  final repo = yaml['repo'];
  if (repo == null) {
    for (final key in ['worktree_name', 'max_worktrees', 'cleanup_after_days']) {
      if (yaml[key] != null) throw ConfigurationException('dispatcher.$key needs dispatcher.repo.');
    }
    return null;
  }
  int? integer(String key) => switch (yaml[key]) {
    null => null,
    final int value => value,
    _ => throw ConfigurationException('dispatcher.$key must be an integer.'),
  };
  final max = integer('max_worktrees') ?? integer('max_agents');
  if (max == null) {
    throw const ConfigurationException('dispatcher.repo needs dispatcher.max_worktrees (or max_agents) as a limit.');
  }
  final days = integer('cleanup_after_days');
  return NewWorktrees(
    repo: _string(repo, 'dispatcher.repo', origin),
    name: yaml['worktree_name'] == null ? null : _string(yaml['worktree_name'], 'dispatcher.worktree_name', origin),
    maxWorktrees: max,
    cleanupAfter: days == null ? null : Duration(days: days),
  );
}

/// `dispatcher.pr`: remote, the `create` and optional `find` commands and
/// `url_pattern`; null without it.
PullRequestConfig? _pullRequest(Object? node, String origin) {
  if (node == null) return null;
  final yaml = _map(node, 'dispatcher.pr', origin);
  const known = {'remote', 'create', 'find', 'url_pattern', 'merge', 'state', 'state_every'};
  for (final key in yaml.keys) {
    if (!known.contains('$key')) {
      throw ConfigurationException('unknown key "dispatcher.pr.$key" (expected ${known.join(', ')}).');
    }
  }
  CommandTemplate? command(String key, [List<String> known = PullRequestConfig.placeholders]) =>
      _template(yaml[key], 'dispatcher.pr.$key', known, origin);
  final every = yaml['state_every'];
  if (every != null && every is! int) {
    throw const ConfigurationException('dispatcher.pr.state_every must be an integer.');
  }
  return PullRequestConfig(
    remote: yaml['remote'] == null ? 'origin' : _string(yaml['remote'], 'dispatcher.pr.remote', origin),
    create: command('create') ?? (throw const ConfigurationException('dispatcher.pr.create is required.')),
    find: command('find'),
    urlPattern: yaml['url_pattern'] == null ? null : _string(yaml['url_pattern'], 'dispatcher.pr.url_pattern', origin),
    merge: command('merge', PullRequestConfig.mergePlaceholders),
    state: command('state', PullRequestConfig.mergePlaceholders),
    stateEvery: Duration(minutes: (every as int?) ?? 2),
  );
}

/// A command given as a list or as one string (split like a shell); null
/// when [node] is null.
CommandTemplate? _template(Object? node, String path, List<String> known, String origin) => switch (node) {
  null => null,
  final List<Object?> list => CommandTemplate(_strings(list, path, origin), label: path, known: known),
  final Object text => CommandTemplate.parse(_string(text, path, origin), label: path, known: known),
};

/// `dispatcher.merge`: strategy (default pr with dispatcher.pr, else
/// local), check, push, remote, command and cleanup; null without it.
MergeConfig? _merge(Object? node, PullRequestConfig? pr, String origin) {
  if (node == null) return null;
  final yaml = _map(node, 'dispatcher.merge', origin);
  const known = {'strategy', 'check', 'push', 'remote', 'command', 'cleanup'};
  for (final key in yaml.keys) {
    if (!known.contains('$key')) {
      throw ConfigurationException('unknown key "dispatcher.merge.$key" (expected ${known.join(', ')}).');
    }
  }
  bool flag(String key, bool fallback) => switch (yaml[key]) {
    null => fallback,
    final bool value => value,
    _ => throw ConfigurationException('dispatcher.merge.$key must be true or false.'),
  };
  return MergeConfig(
    strategy: yaml['strategy'] == null
        ? (pr == null ? MergeStrategy.local : MergeStrategy.pr)
        : MergeStrategy.parse(_string(yaml['strategy'], 'dispatcher.merge.strategy', origin)),
    check: _template(yaml['check'], 'dispatcher.merge.check', MergeConfig.placeholders, origin),
    push: flag('push', false),
    remote: yaml['remote'] == null
        ? pr?.remote ?? 'origin'
        : _string(yaml['remote'], 'dispatcher.merge.remote', origin),
    command: _template(yaml['command'], 'dispatcher.merge.command', MergeConfig.placeholders, origin),
    cleanup: flag('cleanup', true),
  );
}

String _base(String base) => base.startsWith('-') || base.contains(RegExp(r'\s'))
    ? throw ConfigurationException('dispatcher.base "$base" is not a branch name.')
    : base;

/// The profile named by `dispatcher.agent` (built-in or from
/// `dispatcher.agents`), or the legacy `dispatcher.command` as a profile.
AgentProfile _agent(YamlMap yaml, String origin) {
  final command = yaml['command'];
  final name = yaml['agent'];
  if (command != null && name != null) {
    throw const ConfigurationException(
      'give either dispatcher.agent (a profile) or dispatcher.command (a plain command), not both.',
    );
  }
  final custom = _profiles(yaml, origin);
  if (command != null) {
    return AgentProfile(name: 'command', command: _command(command as Object, 'dispatcher.command', origin));
  }
  final chosen = name == null ? 'claude' : _string(name, 'dispatcher.agent', origin);
  final profile = custom[chosen] ?? AgentProfile.builtIns[chosen];
  if (profile == null) {
    final names = {...AgentProfile.builtIns.keys, ...custom.keys};
    throw ConfigurationException('dispatcher.agent: unknown agent "$chosen" (known: ${names.join(', ')}).');
  }
  return profile;
}

/// The profiles of `dispatcher.agents`.
Map<String, AgentProfile> _profiles(YamlMap yaml, String origin) => {
  for (final MapEntry(:key, :value) in _map(yaml['agents'], 'dispatcher.agents', origin).entries)
    '$key': _profile('$key', value, origin),
};

/// One entry of `dispatcher.actions`.
ActionDefinition _action(Object? node, String origin) {
  final yaml = _map(node, 'dispatcher.actions[]', origin);
  const known = {'name', 'statuses', 'on_enter', 'prompt', 'run', 'agent', 'fresh'};
  for (final key in yaml.keys) {
    if (!known.contains('$key')) {
      throw ConfigurationException('unknown key "dispatcher.actions[].$key" (expected ${known.join(', ')}).');
    }
  }
  final name = _string(yaml['name'], 'dispatcher.actions[].name', origin);
  final path = 'dispatcher.actions "$name"';
  final fresh = yaml['fresh'] ?? false;
  if (fresh is! bool) throw ConfigurationException('$path.fresh must be true or false.');
  final run = yaml['run'];
  return ActionDefinition(
    name: name,
    statuses: yaml['statuses'] == null ? null : _strings(yaml['statuses'], '$path.statuses', origin),
    onEnter: yaml['on_enter'] == null ? null : _string(yaml['on_enter'], '$path.on_enter', origin),
    prompt: yaml['prompt'] == null
        ? null
        : TextTemplate(
            _string(yaml['prompt'], '$path.prompt', origin),
            known: ActionDefinition.promptPlaceholders,
            label: '$path.prompt',
          ),
    command: run is List
        ? CommandTemplate(
            _strings(run, '$path.run', origin),
            label: '$path.run',
            known: ActionDefinition.commandPlaceholders,
          )
        : null,
    builtIn: run == null || run is List ? null : _string(run, '$path.run', origin),
    agent: yaml['agent'] == null ? null : _string(yaml['agent'], '$path.agent', origin),
    fresh: fresh,
  );
}

AgentProfile _profile(String name, Object? node, String origin) {
  final path = 'dispatcher.agents.$name';
  final yaml = _map(node, path, origin);
  const known = {'command', 'env', 'output', 'resume'};
  for (final key in yaml.keys) {
    if (!known.contains('$key')) {
      throw ConfigurationException('unknown key "$path.$key" (expected ${known.join(', ')}).');
    }
  }
  final command = yaml['command'];
  if (command == null) throw ConfigurationException('$path.command is required.');
  return AgentProfile(
    name: name,
    command: _command(command as Object, '$path.command', origin),
    environment: {
      for (final MapEntry(:key, :value) in _map(yaml['env'], '$path.env', origin).entries)
        '$key': TextTemplate(
          value == null ? '' : _string(value, '$path.env.$key', origin),
          known: CommandTemplate.placeholders,
          label: '$path.env.$key',
        ),
    },
    output: yaml['output'] == null
        ? AgentOutput.text
        : AgentOutput.parse(_string(yaml['output'], '$path.output', origin), label: '$path.output'),
    resume: switch (yaml['resume']) {
      null => null,
      final List<Object?> list => CommandTemplate(
        _strings(list, '$path.resume', origin),
        label: '$path.resume',
        known: CommandTemplate.resumePlaceholders,
      ),
      final Object text => CommandTemplate.parse(
        _string(text, '$path.resume', origin),
        label: '$path.resume',
        known: CommandTemplate.resumePlaceholders,
      ),
    },
  );
}

CommandTemplate _command(Object node, String path, String origin) => node is List
    ? CommandTemplate(_strings(node, path, origin), label: path)
    : CommandTemplate.parse(_string(node, path, origin), label: path);

Appearance _appearance(Object? node, String origin) {
  if (node == null) return Appearance.none;
  final yaml = _map(node, 'appearance', origin);
  String color(Object value, String path) {
    try {
      return Appearance.color(value, path);
    } on ConfigurationException catch (e) {
      throw ConfigurationException('$origin: ${e.message}');
    }
  }

  Palette palette(String key) {
    final map = _map(yaml[key], 'appearance.$key', origin);
    String? pick(String name) => map[name] == null ? null : color(map[name] as Object, 'appearance.$key.$name');
    return Palette(
      seed: pick('seed'),
      primary: pick('primary'),
      secondary: pick('secondary'),
      background: pick('background'),
    );
  }

  Map<String, String> colors(String section) => {
    for (final MapEntry(:key, :value) in _map(yaml[section], 'appearance.$section', origin).entries)
      if (value != null) '$key': color(value as Object, 'appearance.$section.$key'),
  };

  final mode = '${yaml['mode'] ?? 'system'}'.trim();
  if (!Appearance.modes.contains(mode)) {
    throw ConfigurationException('$origin: appearance.mode must be one of ${Appearance.modes.join(', ')}.');
  }
  return Appearance(
    mode: mode,
    light: palette('light'),
    dark: palette('dark'),
    statuses: colors('statuses'),
    priorities: colors('priorities'),
    types: colors('types'),
    labels: colors('labels'),
  );
}

YamlMap _map(Object? node, String path, String origin) {
  if (node == null) return YamlMap();
  if (node is YamlMap) return node;
  throw ConfigurationException('$origin: "$path" must be a mapping.');
}

List<Object?> _list(Object? node, String path, String origin) {
  if (node is List) return node;
  throw ConfigurationException('$origin: "$path" must be a list.');
}

List<String> _strings(Object? node, String path, String origin) =>
    _list(node, path, origin).map((v) => _string(v, '$path[]', origin)).toList();

String _string(Object? node, String path, String origin) {
  if (node == null || node is Map || node is List) {
    throw ConfigurationException('$origin: "$path" must be a scalar value.');
  }
  final value = node.toString().trim();
  if (value.isEmpty) {
    throw ConfigurationException('$origin: "$path" must not be empty.');
  }
  return value;
}

/// The commented `backlog.yaml` that `backlog init` writes.
String workflowTemplate({String idPrefix = 'T'}) =>
    '''
# Backlog configuration. Items live in items/, saved views in views/.

id:
  prefix: $idPrefix      # new items get ids like $idPrefix-7f3a
  length: 4

# Board order. category: open | active | done
# pickable: agents may take items in this status as ready work.
statuses:
  - id: backlog
    category: open
  - id: todo
    category: open
    pickable: true
  - id: in-progress
    category: active
  - id: review
    category: active
  - id: done
    category: done
  - id: cancelled
    category: done

# From the most urgent.
priorities: [p0, p1, p2, p3]

types: [task, story, epic, bug, decision, idea]

# Leave empty to allow any milestone name.
milestones: []
#  - id: launch
#    title: Production launch
#    due: 2026-12-01

defaults:
  status: backlog
  priority: p2
  type: task

claims:
  lease_minutes: 240   # a claim without heartbeat expires after this

# Colours of the web board (all optional). Quote colours: in YAML an unquoted
# "#..." is a comment.
# appearance:
#   mode: system          # system | light | dark (the app can still switch)
#   light:
#     seed: "#3f51b5"     # a whole palette is generated from it
#     background: "#fafafa"   # optional overrides: primary, secondary, background
#   dark:
#     seed: "#8c9eff"
#   statuses: {todo: "#1e88e5", in-progress: "#fb8c00", review: "#8e24aa", done: "#43a047"}
#   priorities: {p0: "#e53935", p1: "#fb8c00", p2: "#1e88e5", p3: "#90a4ae"}
#   types: {epic: "#6a1b9a", bug: "#c62828"}
#   labels: {infra: "#00897b", ui: "#d81b60"}

# Dispatcher: hands ready items to agents in free worktrees (optional; off
# without this section). A worktree is free when no live claim is held under
# its name. Placeholders in prompt, commands and env: {id}, {title},
# {worktree}, {path} (absolute path of the worktree), {backlog} (absolute path
# of this folder), {branch}; commands and env also {prompt}.
# dispatcher:
#   mode: manual          # manual: propose, a person starts | auto: start by itself
#   max_agents: 2         # at most this many at once (default: one per worktree)
#   worktrees:            # path relative to this folder; a bare name means ../<name>
#     - name: monorepo-2
#       path: ../monorepo-2
#     - monorepo-3
#   # Or (also on top of the list): add worktrees when none is free.
#   repo: ../monorepo     # primary clone; new worktrees go next to it
#   worktree_name: "{repo}-{n}"   # default; the first unused n from 2 on
#   max_worktrees: 4      # listed + created (default: max_agents)
#   cleanup_after_days: 14   # remove created ones idle this long that lose nothing (default: keep)
#   base: main            # new branches agent/<id> start here (an item's own branch field wins)
#   agent: claude         # built-in: claude; unverified presets: codex, gemini, aider
#   # Own profiles (or replacing a built-in one), chosen with agent: <name>:
#   agents:
#     claude-sonnet:
#       command: 'claude -p {prompt} --model sonnet --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools "Bash(backlog *) Bash(git *) Read Edit Write Grep Glob"'
#       env: {MY_SETTING: "{worktree}"}   # BACKLOG_AGENT and BACKLOG_DIR are always set
#       output: claude-stream-json        # text | claude-stream-json | json-lines
#       resume: --resume {session}        # appended to continue the item's last session
#   # The prompt every agent gets (default: claim is yours, read backlog
#   # instructions and backlog show {id}, small commits with the id, then
#   # status=review, never push, ask in the item when unclear):
#   prompt: "You are {worktree}. Work on backlog item {id}: run backlog show {id} first."
#   # The prompt when an agent continues its last session on the item; {news}
#   # tells what happened since (how the run ended, new comments):
#   resume_prompt: "Continue on {id}. Since your last run: {news}"
#   # Actions: buttons on items (statuses: where they show; default every
#   # status, or only the on_enter one) and hooks (on_enter: run by itself,
#   # once, when an item enters that status). Each has exactly one of
#   # prompt (an agent; it continues the item's session unless fresh: true)
#   # and run (a command as a list, or a built-in action by name: noop).
#   # Prompt placeholders as above plus {pr}, {status}, {base}, {action},
#   # {news}; command placeholders {id} {title} {branch} {pr} {status}
#   # {worktree} {path} {backlog} {base} {action}.
#   actions:
#     - name: Address PR comments
#       statuses: [review]
#       prompt: "Go through the unresolved comments of PR {pr}, fix them and answer them."
#       # agent: claude      # profile (default: dispatcher.agent)
#     - name: AI review
#       on_enter: review    # also a button in review
#       fresh: true         # a new session, not the item's own
#       prompt: "Review the changes of {branch} against {base}; write findings with backlog comment {id}."
#     - name: Tests
#       statuses: [review]
#       run: [sh, -c, "mise run check"]   # in the item's worktree; result as a note in the discussion
#     # With a deploy status (category active) after review:
#     # - name: Merge
#     #   on_enter: deploy  # merges when an item is moved to deploy
#     #   statuses: [review]   # and is a button in review
#     #   run: merge        # built-in, see merge below
#   # Pull requests: the agent finishes with `backlog pr <id>`, which pushes
#   # its branch to remote and runs create (no shell; the description on
#   # stdin) unless the item's pr field is set; the URL goes into pr. Without
#   # this section agents never push. Placeholders: {id}, {title}, {branch},
#   # {base}, {remote}, {description}.
#   pr:
#     remote: origin
#     create: 'tea pulls create --head {branch} --base {base} --title "{id}: {title}" --description-file -'
#     # create: 'gh pr create --head {branch} --base {base} --title "{id}: {title}" --body-file -'
#     # find: 'gh pr list --head {branch} --json url --jq ".[0].url"'   # an open PR made elsewhere
#     # url_pattern: 'https://\\S+/pulls/\\d+'   # default: the first URL in the output
#     # Merging (the built-in action merge, strategy pr): {pr} is the URL,
#     # {pr_number} its number; also {id} {title} {branch} {base} {remote}.
#     # merge: tea pulls merge --style rebase {pr_number}
#     # merge: gh pr merge --rebase {pr}
#     # state prints merged / closed / open (a word or JSON with state and
#     # merged); items in an active status with a pr are asked every
#     # state_every minutes, a PR merged elsewhere makes them done.
#     # state: gh pr view {pr} --json state --jq .state
#     # state_every: 2
#   # How the built-in action merge merges (run: merge, typically
#   # on_enter: deploy). Success: the item is done, its branch, created
#   # worktree and session are cleaned up. Failure: the item goes back to
#   # the status it came from, with a comment saying why.
#   merge:
#     strategy: local       # pr (default with pr above) | local (default) | command
#     check: [mise, run, check]   # local: runs after the rebase onto base
#     push: false           # local: push the merged base to remote
#     # remote: origin      # default: pr.remote, else origin
#     # command: [./ship.sh, "{branch}"]   # strategy command; exit 0 = merged
#     cleanup: true         # remove branch and created worktree afterwards
''';
