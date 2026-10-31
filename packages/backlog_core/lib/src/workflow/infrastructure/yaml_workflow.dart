import 'package:yaml/yaml.dart';

import '../../shared/errors.dart';
import '../domain/appearance.dart';
import '../domain/dispatcher_config.dart';
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
  const known = {'mode', 'max_agents', 'worktrees', 'base', 'agent', 'agents', 'prompt', 'command'};
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
    if (worktrees == null) throw const ConfigurationException('dispatcher.worktrees is required.');
    final prompt = yaml['prompt'];
    return DispatcherConfig(
      mode: DispatchMode.parse('${yaml['mode'] ?? 'manual'}'.trim()),
      maxAgents: maxAgents as int?,
      base: yaml['base'] == null ? 'main' : _base(_string(yaml['base'], 'dispatcher.base', origin)),
      agent: _agent(yaml, origin),
      prompt: prompt == null
          ? null
          : TextTemplate(
              _string(prompt, 'dispatcher.prompt', origin),
              known: DispatcherConfig.promptPlaceholders,
              label: 'dispatcher.prompt',
            ),
      worktrees: [
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
  final custom = <String, AgentProfile>{
    for (final MapEntry(:key, :value) in _map(yaml['agents'], 'dispatcher.agents', origin).entries)
      '$key': _profile('$key', value, origin),
  };
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

AgentProfile _profile(String name, Object? node, String origin) {
  final path = 'dispatcher.agents.$name';
  final yaml = _map(node, path, origin);
  const known = {'command', 'env', 'output'};
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
#   base: main            # new branches agent/<id> start here (an item's own branch field wins)
#   agent: claude         # built-in: claude; unverified presets: codex, gemini, aider
#   # Own profiles (or replacing a built-in one), chosen with agent: <name>:
#   agents:
#     claude-sonnet:
#       command: 'claude -p {prompt} --model sonnet --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools "Bash(backlog *) Bash(git *) Read Edit Write Grep Glob"'
#       env: {MY_SETTING: "{worktree}"}   # BACKLOG_AGENT and BACKLOG_DIR are always set
#       output: claude-stream-json        # text | claude-stream-json | json-lines
#   # The prompt every agent gets (default: claim is yours, read backlog
#   # instructions and backlog show {id}, small commits with the id, then
#   # status=review, never push, ask in the item when unclear):
#   prompt: "You are {worktree}. Work on backlog item {id}: run backlog show {id} first."
''';
