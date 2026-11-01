import 'package:path/path.dart' as p;

import '../../shared/errors.dart';
import 'action_definition.dart';
import 'merge_config.dart';

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

  /// Tools Claude Code may use without asking: the backlog CLI, git, mise,
  /// dart and flutter, the project's own scripts (`./greet.sh`,
  /// `./tool/x.sh`), common read-only commands, the web and the file tools.
  /// Everything else is refused (nobody answers permission prompts in
  /// headless mode) unless `dispatcher.allow` adds it; pushing is forbidden
  /// outright ([claudeDisallowedTools]).
  static const claudeAllowedTools =
      'Bash(backlog *) Bash(git *) Bash(mise *) Bash(dart *) Bash(flutter *) Bash(./*) '
      'Bash(ls *) Bash(cat *) Bash(head *) Bash(tail *) Bash(wc *) Bash(find *) Bash(grep *) Bash(rg *) '
      'Bash(jq *) Bash(diff *) Bash(sort *) '
      'Read Edit Write Grep Glob TodoWrite WebFetch WebSearch';

  /// What Claude Code must never run, even though `Bash(git *)` allows git:
  /// pushing in any spelling — `git push`, but also behind git's global
  /// options (`git -C . push`, `git --no-pager push`, `git -c … push`,
  /// all of which a `Bash(git push *)` rule alone lets through, verified
  /// with Claude Code 2.1.312), the plumbing `git send-pack`, and aliases
  /// that would rename push. An agent's work leaves the worktree only
  /// through `backlog pr`, which pushes the item's branch and nothing else.
  static const claudeDisallowedTools = 'Bash(git push *) Bash(git -*) Bash(git send-pack *) Bash(git config *alias*)';

  /// The options of Claude Code that take tool rules.
  static const _allowFlags = {'--allowedTools', '--allowed-tools'};
  static const _denyFlags = {'--disallowedTools', '--disallowed-tools'};

  /// Whether `dispatcher.allow` / `dispatcher.deny` can be applied: the
  /// command passes Claude Code an `--allowedTools` list (the built-in
  /// `claude` profile, or an own one written the same way).
  bool get takesToolRules => command.arguments.any(_allowFlags.contains);

  /// This profile with [allow] added to its `--allowedTools` list and [deny]
  /// to its `--disallowedTools` list (appended when it has none); unchanged
  /// when both are empty or it does not [takesToolRules].
  AgentProfile withToolRules({List<String> allow = const [], List<String> deny = const []}) {
    if ((allow.isEmpty && deny.isEmpty) || !takesToolRules) return this;
    String escape(String rule) => rule.replaceAll('{', '{{').replaceAll('}', '}}');
    final arguments = [...command.arguments];
    var denied = deny.isEmpty;
    for (var i = 0; i < arguments.length - 1; i++) {
      final isDeny = _denyFlags.contains(arguments[i]);
      if (!isDeny && !_allowFlags.contains(arguments[i])) continue;
      final extra = isDeny ? deny : allow;
      if (isDeny) denied = true;
      if (extra.isNotEmpty) arguments[i + 1] = [arguments[i + 1], ...extra.map(escape)].join(' ');
      i++;
    }
    if (!denied) arguments.addAll(['--disallowedTools', deny.map(escape).join(' ')]);
    return AgentProfile(
      name: name,
      command: CommandTemplate(arguments, label: 'agent $name'),
      environment: environment,
      output: output,
      resume: resume,
      builtIn: builtIn,
      verified: verified,
    );
  }

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
        claudeDisallowedTools,
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
    NewWorktrees? newWorktrees,
    List<ActionDefinition> actions = const [],
    Map<String, AgentProfile>? profiles,
    PullRequestConfig? pr,
    MergeConfig? merge,
    List<String> allow = const [],
    List<String> deny = const [],
  }) {
    for (final rule in [...allow, ...deny]) {
      if (rule.trim().isEmpty) {
        throw const ConfigurationException('dispatcher.allow and deny must not hold empty rules.');
      }
    }
    agent = agent.withToolRules(allow: allow, deny: deny);
    profiles = profiles?.map((name, profile) => MapEntry(name, profile.withToolRules(allow: allow, deny: deny)));
    if (worktrees.isEmpty && newWorktrees == null) {
      throw const ConfigurationException(
        'dispatcher.worktrees must list at least one worktree (or set dispatcher.repo).',
      );
    }
    final names = <String>{}, paths = <String>{};
    for (final worktree in worktrees) {
      if (!names.add(worktree.name)) throw ConfigurationException('Duplicate dispatcher worktree "${worktree.name}".');
      if (!paths.add(p.normalize(worktree.path))) {
        throw ConfigurationException('Dispatcher worktrees share the path "${worktree.path}".');
      }
    }
    if (newWorktrees != null && newWorktrees.maxWorktrees < worktrees.length) {
      throw ConfigurationException(
        'dispatcher.max_worktrees (${newWorktrees.maxWorktrees}) is less than the ${worktrees.length} listed worktrees.',
      );
    }
    final limit = maxAgents ?? newWorktrees?.maxWorktrees ?? worktrees.length;
    if (limit < 1) throw const ConfigurationException('dispatcher.max_agents must be at least 1.');
    final usable = {
      for (final MapEntry(:key, :value) in AgentProfile.builtIns.entries)
        key: value.withToolRules(allow: allow, deny: deny),
      ...?profiles,
      agent.name: agent,
    };
    final actionNames = <String>{};
    for (final action in actions) {
      if (!actionNames.add(action.name)) throw ConfigurationException('Duplicate dispatcher action "${action.name}".');
      if (action.agent case final name? when !usable.containsKey(name)) {
        throw ConfigurationException(
          'dispatcher.actions "${action.name}": unknown agent "$name" (known: ${usable.keys.join(', ')}).',
        );
      }
    }
    final merging = merge != null || actions.any((action) => action.builtIn == 'merge');
    final mergeConfig =
        merge ??
        MergeConfig(strategy: pr == null ? MergeStrategy.local : MergeStrategy.pr, remote: pr?.remote ?? 'origin');
    if (merging && mergeConfig.strategy == MergeStrategy.pr && pr?.merge == null) {
      throw ConfigurationException(
        'dispatcher.merge: strategy pr${merge == null ? ' (the default with dispatcher.pr)' : ''} needs '
        '${pr == null ? 'dispatcher.pr with ' : ''}dispatcher.pr.merge, e.g. '
        '"tea pulls merge --style rebase {pr_number}" or "gh pr merge --rebase {pr}"; '
        'or set dispatcher.merge.strategy to local or command.',
      );
    }
    return DispatcherConfig._(
      List.unmodifiable(worktrees),
      agent,
      prompt ??
          TextTemplate(
            pr == null ? defaultPrompt : defaultPullRequestPrompt,
            known: promptPlaceholders,
            label: 'dispatcher.prompt',
          ),
      resumePrompt ??
          TextTemplate(
            pr == null ? defaultResumePrompt : defaultPullRequestResumePrompt,
            known: resumePromptPlaceholders,
            label: 'dispatcher.resume_prompt',
          ),
      mode,
      limit,
      base,
      newWorktrees,
      List.unmodifiable(actions),
      Map.unmodifiable(usable),
      pr,
      mergeConfig,
      List.unmodifiable(allow),
      List.unmodifiable(deny),
    );
  }

  DispatcherConfig._(
    this.worktrees,
    this.agent,
    this.prompt,
    this.resumePrompt,
    this.mode,
    this.maxAgents,
    this.base,
    this.newWorktrees,
    this.actions,
    this.profiles,
    this.pr,
    this.merge,
    this.allow,
    this.deny,
  );

  /// What the prompt may refer to: the item id and title, the worktree name,
  /// its absolute path, the absolute path of the backlog folder and the
  /// branch prepared for the agent.
  static const promptPlaceholders = ['id', 'title', 'worktree', 'path', 'backlog', 'branch'];

  /// What the prompt of a resumed session may refer to: [promptPlaceholders]
  /// and `{news}`, what happened since the agent's last run (how it ended,
  /// new comments of others in the discussion).
  static const resumePromptPlaceholders = [...promptPlaceholders, 'news'];

  /// How every default prompt (and the frame of prompt actions) tells the
  /// agent to talk to people: the discussion carries questions, answers and
  /// problems only, no acknowledgements, progress or summaries of work that
  /// went well.
  static const talkRules =
      'Talking to people: the discussion of the item is for questions, answers and problems only. Write a comment '
      'only to ask what you need to know (`backlog ask {id} "<your question>"`, then stop), to answer a question a '
      'person asked you, or when something failed or you could not finish: a push or pull request failed, checks or '
      'tests do not pass, a permission was denied, a tool is missing. Then write one comment '
      '(`backlog comment {id} "…"`) with what happened and what is needed; when a person has to decide something, '
      'ask instead. Never acknowledge an answer ("thanks, on it"), never report progress and never summarise work '
      'that went well in comments: that belongs in commit messages (and the pull request description). Write in the '
      'language the people in the item use.';

  /// How every default prompt (and the frames of prompt actions and fixes)
  /// tells the agent to tick off the item's checklist: through the CLI, since
  /// the item file lies outside its worktree and editing it is denied.
  static const checklistRules =
      'The checklist of the item (`- [ ]` lines in its body): tick off what you finished with '
      '`backlog check {id} <number or text>` (`backlog check {id}` lists it numbered, `backlog uncheck` undoes); '
      'never edit the item file for that.';

  /// How every default prompt tells the agent to run things so that its tool
  /// whitelist lets them through (nobody can approve anything else).
  static const runRules =
      'Running things: run the project\'s scripts directly as `./script args` (not `sh script`), one command per '
      'call without `;` or `&&` chains, and prefer your Read, Grep and Glob tools for files; besides backlog, git, '
      'mise, dart, flutter, common read-only commands (ls, cat, grep, find, …) and web search/fetch, only what the '
      'project allows runs: anything else needs an approval nobody can give and is denied. Keep every command on '
      'one line: for a long or multi-line text write it with your Write tool to a file in $scratchFolder/ (git '
      'ignores that folder in your worktree) and pass the file: `backlog comment {id} --file $scratchFolder/x.md` '
      '(also `ask` and `review`).';

  /// The folder (relative to an agent's worktree) for texts an agent writes
  /// for the backlog CLI ([runRules]); the launcher makes git ignore it
  /// (`info/exclude`), so the worktree stays clean.
  static const scratchFolder = '.kanban-ai';

  /// The prompt every agent gets unless `dispatcher.prompt` replaces it.
  static const defaultPrompt =
      'You are the coding agent {worktree}, working on backlog item {id} ("{title}") in this git worktree.\n'
      '1. First run `backlog instructions` and `backlog show {id}` and follow them. The item is already claimed '
      'for you (BACKLOG_AGENT={worktree}); do not take other items.\n'
      '2. The worktree is on branch {branch}, prepared for this item: commit there and do not switch branches. '
      'Make small commits; every commit message contains {id}.\n'
      '3. When the work is finished, run `backlog set {id} status=review`.\n'
      '4. Never push and never open pull requests.\n'
      '5. If something is unclear or blocks you, ask with `backlog ask {id} "<your question>"`, leave the status as '
      'it is and stop; you will be resumed with the answer.\n'
      '6. If a discussion in the item changes what it asks for, $describeRule\n'
      '$checklistRules\n$talkRules\n$runRules';

  /// How the default prompts tell the agent to update what its item asks
  /// for: through `backlog describe`, since the item file lies outside its
  /// worktree.
  static const describeRule =
      'update its description or acceptance criteria with `backlog describe {id} --file $scratchFolder/item-{id}.md` '
      '(the text written with your Write tool replaces the description above `## Discussion`; add '
      '`--section "Acceptance criteria"` to replace only that section). Never edit the item file or the comments; '
      'no comment about it is needed.';

  /// The prompt for continuing an agent's earlier session on the same item
  /// (unless `dispatcher.resume_prompt` replaces it).
  static const defaultResumePrompt =
      'You are the coding agent {worktree} again, continuing your earlier session on backlog item {id} ("{title}"). '
      'The item is claimed for you again and the worktree is on branch {branch}.\n'
      'Since your last run: {news}\n'
      'Run `backlog show {id}` to see the item as it is now. Then:\n'
      '- If the new comments only ask you something (e.g. why you did something), answer with '
      '`backlog comment {id} "…"` and stop: change no code and leave the status as it is.\n'
      '- If they answer your question or ask for changes, continue the work (no comment to acknowledge it) under the same rules as before: small commits containing {id} on {branch}, '
      '`backlog set {id} status=review` when finished, never push.\n'
      '- Without new comments, continue the work under the same rules.\n'
      '- If the discussion changed what the item asks for, $describeRule\n'
      '- If something is still unclear, ask with `backlog ask {id} "<your question>"` and stop.\n'
      '$checklistRules\n$talkRules\n$runRules';

  /// The prompt every agent gets when the project opens pull requests
  /// (`dispatcher.pr`) unless `dispatcher.prompt` replaces it: the agent
  /// hands its work over with `backlog pr`, which pushes only its branch.
  static const defaultPullRequestPrompt =
      'You are the coding agent {worktree}, working on backlog item {id} ("{title}") in this git worktree.\n'
      '1. First run `backlog instructions` and `backlog show {id}` and follow them. The item is already claimed '
      'for you (BACKLOG_AGENT={worktree}); do not take other items.\n'
      '2. The worktree is on branch {branch}, prepared for this item: commit there and do not switch branches. '
      'Make small commits; every commit message contains {id}.\n'
      '3. When the work is finished, open a pull request: write its description yourself (what changed and why, '
      'how you verified it, and that it implements backlog item {id}) with your Write tool to '
      '$scratchFolder/pr-{id}.md and run `backlog pr {id} --description-file $scratchFolder/pr-{id}.md`. It pushes '
      '{branch} and opens the pull request (when one exists already, it only pushes). Then run '
      '`backlog set {id} status=review`.\n'
      '4. Never run `git push` yourself, never push other branches and never merge: `backlog pr {id}` is the only '
      'way your work leaves this worktree. If it fails, say why with `backlog comment {id} "…"` and still set the '
      'status to review.\n'
      '5. If something is unclear or blocks you, ask with `backlog ask {id} "<your question>"`, leave the status as '
      'it is and stop; you will be resumed with the answer.\n'
      '6. If a discussion in the item changes what it asks for, $describeRule\n'
      '$checklistRules\n$talkRules\n$runRules';

  /// The resume prompt when the project opens pull requests (`dispatcher.pr`).
  static const defaultPullRequestResumePrompt =
      'You are the coding agent {worktree} again, continuing your earlier session on backlog item {id} ("{title}"). '
      'The item is claimed for you again and the worktree is on branch {branch}.\n'
      'Since your last run: {news}\n'
      'Run `backlog show {id}` to see the item as it is now. Then:\n'
      '- If the new comments only ask you something (e.g. why you did something), answer with '
      '`backlog comment {id} "…"` and stop: change no code and leave the status as it is.\n'
      '- If they answer your question or ask for changes, continue the work (no comment to acknowledge it) under the same rules as before: small commits containing {id} on {branch}; when finished, '
      '`backlog pr {id}` (it pushes {branch} and opens the pull request when there is none yet; give '
      '`--description-file $scratchFolder/pr-{id}.md` then, written with your Write tool) and '
      '`backlog set {id} status=review`; never run `git push` yourself.\n'
      '- Without new comments, continue the work under the same rules.\n'
      '- If the discussion changed what the item asks for, $describeRule\n'
      '- If something is still unclear, ask with `backlog ask {id} "<your question>"` and stop.\n'
      '$checklistRules\n$talkRules\n$runRules';

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

  /// How the dispatcher adds worktrees of its own when none of [worktrees]
  /// is free (`dispatcher.repo`); null when it only uses [worktrees].
  final NewWorktrees? newWorktrees;

  /// `dispatcher.actions`: buttons and status hooks, in the configured order.
  final List<ActionDefinition> actions;

  /// Every agent profile an action may name: the built-in ones, those of
  /// `dispatcher.agents` and [agent].
  final Map<String, AgentProfile> profiles;

  /// Claude Code tool rules (`dispatcher.allow`) added to the `--allowedTools`
  /// of every profile that has such a list (the built-in `claude`); already
  /// applied to [agent] and [profiles].
  final List<String> allow;

  /// Claude Code tool rules (`dispatcher.deny`) added to the
  /// `--disallowedTools` of the same profiles. The built-in push ban stays.
  final List<String> deny;

  /// How finished work becomes a pull request (`dispatcher.pr`); null when
  /// the project opens none (the default prompt then forbids pushing).
  final PullRequestConfig? pr;

  /// How the built-in action `merge` merges (`dispatcher.merge`; defaults
  /// to strategy `pr` with [pr], else `local`).
  final MergeConfig merge;

  /// The command of [agent].
  CommandTemplate get command => agent.command;

  /// The action called [name]; null when there is none.
  ActionDefinition? action(String name) {
    for (final action in actions) {
      if (action.name == name) return action;
    }
    return null;
  }

  /// The profile a prompt [action] starts: its `agent`, else [agent].
  AgentProfile profileFor(ActionDefinition action) => action.agent == null ? agent : profiles[action.agent] ?? agent;

  /// The same configuration with [worktrees] in place of the listed ones
  /// (e.g. the listed ones plus those the dispatcher created).
  DispatcherConfig withWorktrees(List<WorktreeDefinition> worktrees) => DispatcherConfig._(
    List.unmodifiable(worktrees),
    agent,
    prompt,
    resumePrompt,
    mode,
    maxAgents,
    base,
    newWorktrees,
    actions,
    profiles,
    pr,
    merge,
    allow,
    deny,
  );

  WorktreeDefinition? worktree(String name) {
    for (final worktree in worktrees) {
      if (worktree.name == name) return worktree;
    }
    return null;
  }
}

/// Worktrees the dispatcher adds by itself (`dispatcher.repo`,
/// `worktree_name`, `max_worktrees`, `cleanup_after_days`, `setup`): when no
/// worktree is free, it runs `git worktree add` in the primary clone [repo]
/// for the next name of [name] (`{repo}-{n}` by default: the first number
/// from 2 on whose name and folder are unused), next to the clone, then the
/// [setup] commands in it.
final class NewWorktrees {
  NewWorktrees({
    required this.repo,
    String? name,
    required this.maxWorktrees,
    this.cleanupAfter,
    List<CommandTemplate> setup = const [],
  }) : name = TextTemplate(name ?? defaultName, known: const ['repo', 'n'], label: 'dispatcher.worktree_name'),
       setup = List.unmodifiable(setup) {
    if (repo.trim().isEmpty) throw const ConfigurationException('dispatcher.repo must not be empty.');
    if (!this.name.text.contains('{n}')) {
      throw const ConfigurationException('dispatcher.worktree_name must contain {n}.');
    }
    if (maxWorktrees < 1) throw const ConfigurationException('dispatcher.max_worktrees must be at least 1.');
    if (cleanupAfter case final after? when after <= Duration.zero) {
      throw const ConfigurationException('dispatcher.cleanup_after_days must be at least 1.');
    }
    final example = nameFor(2);
    if (!WorktreeDefinition._namePattern.hasMatch(example) || example.contains('/')) {
      throw ConfigurationException(
        'dispatcher.worktree_name gives "$example", which is not a worktree name '
        '(letters, digits, ".", "_" and "-").',
      );
    }
  }

  static const defaultName = '{repo}-{n}';

  /// The primary clone as written: absolute, or relative to the backlog folder.
  final String repo;

  /// Name of the n-th worktree; `{repo}` is the folder name of [repo].
  final TextTemplate name;

  /// At most this many worktrees in all: the listed ones plus those the
  /// dispatcher created.
  final int maxWorktrees;

  /// Remove a worktree the dispatcher created after it was idle this long,
  /// when that loses nothing (clean, nothing that is not in the base
  /// branch); null keeps them.
  final Duration? cleanupAfter;

  /// Commands that prepare a new worktree (`mise trust`, fetching
  /// dependencies), run one after another in it (no shell) before any agent
  /// starts there; when one fails, the worktree is removed again.
  final List<CommandTemplate> setup;

  /// What [setup] commands may refer to: the new worktree's name and
  /// absolute path, the primary clone and the base branch.
  static const setupPlaceholders = ['worktree', 'path', 'repo', 'base'];

  /// [repo] made absolute against the backlog folder [backlogRoot].
  String resolveRepo(String backlogRoot) => p.normalize(p.isAbsolute(repo) ? repo : p.join(backlogRoot, repo));

  /// The name of the [n]-th worktree.
  String nameFor(int n) => name.render({'repo': p.basename(p.normalize(repo)), 'n': '$n'});

  /// The worktree called [worktreeName]: a folder next to the primary clone.
  WorktreeDefinition worktree(String worktreeName, String backlogRoot) =>
      WorktreeDefinition(worktreeName, p.join(p.dirname(resolveRepo(backlogRoot)), worktreeName));
}

/// How an agent's branch becomes a pull request (`dispatcher.pr`): the
/// branch is pushed to [remote], then [create] runs (no shell) in the
/// worktree with the description on its standard input, and the pull
/// request's URL is taken from its output with [urlPattern]. [find], when
/// given, prints the URL of an open pull request of the branch (nothing
/// when there is none), so that one made outside the board is not made
/// twice.
final class PullRequestConfig {
  PullRequestConfig({
    this.remote = 'origin',
    required this.create,
    this.find,
    this.review,
    String? urlPattern,
    this.merge,
    this.state,
    this.stateEvery = const Duration(minutes: 2),
  }) : urlPattern = _pattern(urlPattern) {
    if (remote.isEmpty || remote.startsWith('-') || remote.contains(RegExp(r'\s'))) {
      throw ConfigurationException('dispatcher.pr.remote "$remote" is not a remote name.');
    }
    if (stateEvery < const Duration(minutes: 1)) {
      throw const ConfigurationException('dispatcher.pr.state_every must be at least 1 (minutes).');
    }
  }

  static RegExp _pattern(String? source) {
    if (source == null) return defaultUrlPattern;
    try {
      return RegExp(source, multiLine: true);
    } on FormatException catch (error) {
      throw ConfigurationException('dispatcher.pr.url_pattern is not a regular expression: ${error.message}.');
    }
  }

  /// What [create] and [find] may refer to: the item id and title, the
  /// branch, the base branch, the remote and the description (which
  /// [create] also gets on its standard input).
  static const placeholders = ['id', 'title', 'branch', 'base', 'remote', 'description'];

  /// What [merge] and [state] may refer to: the item id and title, the
  /// branch, the base, the remote, the pull request's URL `{pr}` and its
  /// number `{pr_number}` ([numberOf]).
  static const mergePlaceholders = ['id', 'title', 'branch', 'base', 'remote', 'pr', 'pr_number'];

  /// What [review] may refer to: the item id and title, the branch, the base
  /// branch, the remote, the pull request (`{pr}`: the item's `pr` field,
  /// `{pr_number}`: [numberOf] it), the verdict (`ok`, `changes`) and the
  /// text posted (`{body}`, also on its standard input).
  static const reviewPlaceholders = ['id', 'title', 'branch', 'base', 'remote', 'pr', 'pr_number', 'verdict', 'body'];

  /// The number of the pull request [url] names (`…/pulls/12`, `…/pull/12`,
  /// `…/merge_requests/12`, `#7`, `7`): its last path segment made of
  /// digits; null when it names none.
  static String? numberOf(String url) => RegExp(r'(?:^#?|/)(\d+)/?(?:[?#].*)?$').firstMatch(url.trim())?.group(1);

  /// The first http(s) URL.
  static final defaultUrlPattern = RegExp(r'https?://[^\s<>"`)\]]+');

  /// Where the branch is pushed (`dispatcher.pr.remote`, default `origin`).
  final String remote;

  /// Opens the pull request (`dispatcher.pr.create`).
  final CommandTemplate create;

  /// Prints the URL of an open pull request of the branch
  /// (`dispatcher.pr.find`); null when not configured.
  final CommandTemplate? find;

  /// Merges the item's pull request (`dispatcher.pr.merge`, used by the
  /// built-in action `merge` with strategy `pr`); null when not configured.
  final CommandTemplate? merge;

  /// Prints the state of the item's pull request (`dispatcher.pr.state`):
  /// `merged`, `closed` or `open`, as a word or as JSON (`state`, `merged`).
  /// With it the dispatcher notices pull requests merged outside the board.
  final CommandTemplate? state;

  /// How often [state] is asked per item at most (`state_every`, minutes;
  /// default 2).
  final Duration stateEvery;

  /// Posts the summary of a review (`backlog review`) to the item's pull
  /// request as a comment (`dispatcher.pr.review`); null when not
  /// configured.
  final CommandTemplate? review;

  /// Finds the URL in the output of [create] or [find]: its first group,
  /// else the whole match.
  final RegExp urlPattern;

  /// The pull request's URL in [output] (terminal colour codes removed);
  /// null when there is none.
  String? urlIn(String output) {
    final match = urlPattern.firstMatch(output.replaceAll(RegExp(r'\x1B\[[0-9;?]*[A-Za-z]'), ''));
    if (match == null) return null;
    final url = (match.groupCount > 0 ? match.group(1) : match.group(0))?.trim();
    return url == null || url.isEmpty ? null : url;
  }
}
