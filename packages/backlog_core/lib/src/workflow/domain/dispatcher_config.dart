import 'package:path/path.dart' as p;

import '../../shared/errors.dart';

/// Whether the dispatcher starts agents by itself or waits for a person.
enum DispatchMode {
  /// Ready work is started on free worktrees as soon as it appears.
  auto,

  /// The dispatcher only proposes; a person presses "Start" in the UI.
  manual;

  static DispatchMode parse(String value) => DispatchMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw ConfigurationException('dispatcher.mode must be auto or manual, got "$value".'),
  );
}

/// One worktree an agent can run in. Its [name] is also the agent name the
/// claim is taken under, so a live claim of that name means "busy".
final class WorktreeDefinition {
  WorktreeDefinition(this.name, this.path) {
    if (!_namePattern.hasMatch(name)) {
      throw ConfigurationException(
        'Worktree name "$name" may contain only letters, digits, ".", "_" and "-" and must start with a letter or digit.',
      );
    }
    if (path.trim().isEmpty) throw ConfigurationException('Worktree "$name" needs a path.');
  }

  static final _namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  final String name;

  /// As written in `backlog.yaml`: absolute, or relative to the backlog folder.
  final String path;

  /// [path] made absolute against the backlog folder [backlogRoot].
  String resolvePath(String backlogRoot) => p.normalize(p.isAbsolute(path) ? path : p.join(backlogRoot, path));
}

/// A text with `{placeholder}`s filled in per item (the prompt, environment
/// values). `{{` and `}}` stand for literal braces.
final class TextTemplate {
  /// Rejects placeholders other than [known]; [label] names the setting in
  /// error messages.
  TextTemplate(this.text, {required List<String> known, required String label}) {
    _validate(text, known, label);
  }

  final String text;

  /// [text] with placeholders replaced by [values] (a missing one becomes empty).
  String render(Map<String, String> values) => _fill(text, (name) => values[name] ?? '');

  @override
  String toString() => text;
}

/// The command that starts an agent, as a list of arguments (no shell) whose
/// `{placeholder}`s are filled in per item. `{{` and `}}` stand for literal
/// braces.
final class CommandTemplate {
  CommandTemplate(List<String> arguments, {String label = 'dispatcher.command', List<String> known = placeholders})
    : arguments = List.unmodifiable(arguments) {
    if (arguments.isEmpty || arguments.first.trim().isEmpty) {
      throw ConfigurationException('$label must not be empty.');
    }
    for (final argument in arguments) {
      _validate(argument, known, label);
    }
  }

  /// Splits [command] into arguments like a POSIX shell would (whitespace,
  /// '…' and "…" quotes, backslash escapes) without running one: there are
  /// no pipes, variables or globs, so filled-in values can never inject.
  factory CommandTemplate.parse(
    String command, {
    String label = 'dispatcher.command',
    List<String> known = placeholders,
  }) => CommandTemplate(
    splitWords(command, label: label),
    label: label,
    known: known,
  );

  /// What a command may refer to: the item id and title, the worktree name,
  /// its absolute path, the absolute path of the backlog folder and the
  /// rendered prompt (`dispatcher.prompt`).
  static const placeholders = [...DispatcherConfig.promptPlaceholders, 'prompt'];

  /// What the arguments that resume a session may refer to: the command's
  /// placeholders and the `{session}` id.
  static const resumePlaceholders = [...placeholders, 'session'];

  final List<String> arguments;

  /// The arguments with placeholders replaced by [values] (keys from
  /// [placeholders]; a missing one becomes empty).
  List<String> render(Map<String, String> values) => [
    for (final argument in arguments) _fill(argument, (name) => values[name] ?? ''),
  ];

  /// The program, i.e. the first argument.
  String get executable => arguments.first;

  @override
  String toString() => join(arguments);

  /// [arguments] as one shell-quoted line, for logs and display.
  static String join(List<String> arguments) => arguments.map(_quote).join(' ');

  static String _quote(String argument) => RegExp(r'''^[A-Za-z0-9_./:={}@%+,-]+$''').hasMatch(argument)
      ? argument
      : "'${argument.replaceAll("'", r"'\''")}'";

  /// Shell-like word splitting of [command]; see [CommandTemplate.parse].
  static List<String> splitWords(String command, {String label = 'dispatcher.command'}) {
    final words = <String>[];
    final word = StringBuffer();
    var inWord = false;
    String? quote;
    for (var i = 0; i < command.length; i++) {
      final char = command[i];
      if (quote == "'") {
        if (char == "'") {
          quote = null;
        } else {
          word.write(char);
        }
      } else if (quote == '"') {
        if (char == '"') {
          quote = null;
        } else if (char == r'\' && i + 1 < command.length && r'"\$`'.contains(command[i + 1])) {
          word.write(command[++i]);
        } else {
          word.write(char);
        }
      } else if (char == "'" || char == '"') {
        quote = char;
        inWord = true;
      } else if (char == r'\' && i + 1 < command.length) {
        word.write(command[++i]);
        inWord = true;
      } else if (char.trim().isEmpty) {
        if (inWord) words.add(word.toString());
        word.clear();
        inWord = false;
      } else {
        word.write(char);
        inWord = true;
      }
    }
    if (quote != null) throw ConfigurationException('$label: unterminated $quote quote.');
    if (inWord) words.add(word.toString());
    return words;
  }
}

final _token = RegExp(r'\{\{|\}\}|\{([A-Za-z_]+)\}');

String _fill(String text, String Function(String name) value) => text.replaceAllMapped(
  _token,
  (match) => switch (match[0]) {
    '{{' => '{',
    '}}' => '}',
    _ => value(match[1]!),
  },
);

void _validate(String text, List<String> known, String label) => _fill(text, (name) {
  if (!known.contains(name)) {
    throw ConfigurationException(
      '$label: unknown placeholder "{$name}" (known: ${known.map((p) => '{$p}').join(', ')}).',
    );
  }
  return '';
});

/// How an agent writes its output; tells later readers of the log (session
/// id, progress) how to parse it.
enum AgentOutput {
  /// Plain text.
  text('text'),

  /// Claude Code's `--output-format stream-json`: one JSON event per line,
  /// ending with a `result` event that carries the `session_id`.
  claudeStreamJson('claude-stream-json'),

  /// Some other JSON object per line (e.g. `codex exec --json`).
  jsonLines('json-lines');

  const AgentOutput(this.id);

  /// The name used in `backlog.yaml`.
  final String id;

  static AgentOutput parse(String value, {String label = 'output'}) => values.firstWhere(
    (output) => output.id == value,
    orElse: () =>
        throw ConfigurationException('$label must be one of ${values.map((o) => o.id).join(', ')}, got "$value".'),
  );
}

/// One way to start a coding agent: its command (with `{prompt}` and the
/// item's placeholders), extra environment and output format. Built-in
/// profiles ([builtIns]) can be used by name; `dispatcher.agents` adds or
/// replaces profiles.
final class AgentProfile {
  AgentProfile({
    required this.name,
    required this.command,
    Map<String, TextTemplate> environment = const {},
    this.output = AgentOutput.text,
    this.resume,
    this.builtIn = false,
    this.verified = true,
  }) : environment = Map.unmodifiable(environment) {
    for (final key in environment.keys) {
      if (!_envName.hasMatch(key)) {
        throw ConfigurationException('Agent "$name": "$key" is not a valid environment variable name.');
      }
    }
  }

  static final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  final String name;
  final CommandTemplate command;

  /// Set for the agent's process on top of the server's environment (and of
  /// `BACKLOG_AGENT`, `BACKLOG_DIR`); values may use the command's placeholders.
  final Map<String, TextTemplate> environment;
  final AgentOutput output;

  /// Arguments appended to [command] to continue an earlier session of the
  /// agent (`{session}` is its id), e.g. `--resume {session}`; null when the
  /// agent cannot resume. Sessions are only known from output the
  /// launcher can read a session id from ([AgentOutput.claudeStreamJson]).
  final CommandTemplate? resume;

  /// Whether a session of this profile can be continued.
  bool get canResume => resume != null && output == AgentOutput.claudeStreamJson;

  /// Shipped with kanban-ai rather than defined in `backlog.yaml`.
  final bool builtIn;

  /// Tried with the real CLI; unverified presets may need adjusting.
  final bool verified;

  /// Tools Claude Code may use without asking: the backlog CLI, git, mise
  /// tasks and the file tools. Everything else is refused (nobody answers
  /// permission prompts in headless mode); pushing is forbidden outright.
  static const claudeAllowedTools = 'Bash(backlog *) Bash(git *) Bash(mise run *) Read Edit Write Grep Glob TodoWrite';

  /// The profiles usable without defining them. Only `claude` is verified
  /// (Claude Code 2.1); the others are presets after the CLIs' documentation.
  static final Map<String, AgentProfile> builtIns = {
    'claude': AgentProfile(
      name: 'claude',
      // Never --bare (it ignores the subscription login) and never
      // --dangerously-skip-permissions: a tool whitelist and acceptEdits.
      command: CommandTemplate([
        'claude',
        '-p',
        '{prompt}',
        '--output-format',
        'stream-json',
        '--verbose',
        '--permission-mode',
        'acceptEdits',
        '--permission-prompts',
        'none',
        '--allowedTools',
        claudeAllowedTools,
        '--disallowedTools',
        'Bash(git push *)',
      ], label: 'agent claude'),
      output: AgentOutput.claudeStreamJson,
      resume: CommandTemplate(
        ['--resume', '{session}'],
        label: 'agent claude resume',
        known: CommandTemplate.resumePlaceholders,
      ),
      builtIn: true,
    ),
    'codex': AgentProfile(
      name: 'codex',
      command: CommandTemplate(['codex', 'exec', '--full-auto', '--json', '{prompt}'], label: 'agent codex'),
      output: AgentOutput.jsonLines,
      builtIn: true,
      verified: false,
    ),
    'gemini': AgentProfile(
      name: 'gemini',
      command: CommandTemplate(['gemini', '--approval-mode', 'auto_edit', '-p', '{prompt}'], label: 'agent gemini'),
      builtIn: true,
      verified: false,
    ),
    'aider': AgentProfile(
      name: 'aider',
      command: CommandTemplate(['aider', '--yes-always', '--message', '{prompt}'], label: 'agent aider'),
      builtIn: true,
      verified: false,
    ),
  };
}

/// The optional `dispatcher` section of `backlog.yaml`: which worktrees
/// agents may run in, how many at once, which agent to start with which
/// prompt and whether to do it automatically. Without the section there is
/// no dispatcher.
final class DispatcherConfig {
  factory DispatcherConfig({
    required List<WorktreeDefinition> worktrees,
    required AgentProfile agent,
    TextTemplate? prompt,
    TextTemplate? resumePrompt,
    DispatchMode mode = DispatchMode.manual,
    int? maxAgents,
    String base = 'main',
  }) {
    if (worktrees.isEmpty) throw const ConfigurationException('dispatcher.worktrees must list at least one worktree.');
    final names = <String>{}, paths = <String>{};
    for (final worktree in worktrees) {
      if (!names.add(worktree.name)) throw ConfigurationException('Duplicate dispatcher worktree "${worktree.name}".');
      if (!paths.add(p.normalize(worktree.path))) {
        throw ConfigurationException('Dispatcher worktrees share the path "${worktree.path}".');
      }
    }
    final limit = maxAgents ?? worktrees.length;
    if (limit < 1) throw const ConfigurationException('dispatcher.max_agents must be at least 1.');
    return DispatcherConfig._(
      List.unmodifiable(worktrees),
      agent,
      prompt ?? TextTemplate(defaultPrompt, known: promptPlaceholders, label: 'dispatcher.prompt'),
      resumePrompt ??
          TextTemplate(defaultResumePrompt, known: resumePromptPlaceholders, label: 'dispatcher.resume_prompt'),
      mode,
      limit,
      base,
    );
  }

  DispatcherConfig._(this.worktrees, this.agent, this.prompt, this.resumePrompt, this.mode, this.maxAgents, this.base);

  /// What the prompt may refer to: the item id and title, the worktree name,
  /// its absolute path, the absolute path of the backlog folder and the
  /// branch prepared for the agent.
  static const promptPlaceholders = ['id', 'title', 'worktree', 'path', 'backlog', 'branch'];

  /// What the prompt of a resumed session may refer to: [promptPlaceholders]
  /// and `{news}`, what happened since the agent's last run.
  static const resumePromptPlaceholders = [...promptPlaceholders, 'news'];

  /// The prompt every agent gets unless `dispatcher.prompt` replaces it.
  static const defaultPrompt =
      'You are the coding agent {worktree}, working on backlog item {id} ("{title}") in this git worktree.\n'
      '1. First run `backlog instructions` and `backlog show {id}` and follow them. The item is already claimed '
      'for you (BACKLOG_AGENT={worktree}); do not take other items.\n'
      '2. The worktree is on branch {branch}, prepared for this item: commit there and do not switch branches. '
      'Make small commits; every commit message contains {id}.\n'
      '3. When the work is finished, run `backlog set {id} status=review`.\n'
      '4. Never push and never open pull requests.\n'
      '5. If something is unclear or blocks you, write your question into the body of the item (its file is shown '
      'by `backlog show {id}`), leave its status as it is and stop.';

  /// The prompt for continuing an agent's earlier session on the same item
  /// (unless `dispatcher.resume_prompt` replaces it).
  static const defaultResumePrompt =
      'You are the coding agent {worktree} again, continuing your earlier session on backlog item {id} ("{title}"). '
      'The item is claimed for you again and the worktree is on branch {branch}.\n'
      'Since your last run: {news}\n'
      'Run `backlog show {id}` to see the item as it is now, then continue the work under the same rules as before: '
      'small commits containing {id} on {branch}, `backlog set {id} status=review` when finished, never push. '
      'If something is unclear or blocks you, write your question into the body of the item, leave its status as '
      'it is and stop.';

  /// In order of preference: free work goes to the first free worktree.
  final List<WorktreeDefinition> worktrees;

  /// The agent profile started for each assignment.
  final AgentProfile agent;

  /// The prompt, shared by all agents; fills `{prompt}` in the command.
  final TextTemplate prompt;

  /// The prompt when an agent continues its earlier session on an item.
  final TextTemplate resumePrompt;
  final DispatchMode mode;

  /// At most this many agents run at once (defaults to one per worktree;
  /// more than there are worktrees has no effect).
  final int maxAgents;

  /// The branch new item branches start from (`dispatcher.base`, default
  /// `main`).
  final String base;

  /// The command of [agent].
  CommandTemplate get command => agent.command;

  WorktreeDefinition? worktree(String name) {
    for (final worktree in worktrees) {
      if (worktree.name == name) return worktree;
    }
    return null;
  }
}
