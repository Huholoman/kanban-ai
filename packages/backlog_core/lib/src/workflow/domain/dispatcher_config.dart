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

/// The command that starts an agent, as a list of arguments (no shell) whose
/// `{placeholder}`s are filled in per item. `{{` and `}}` stand for literal
/// braces.
final class CommandTemplate {
  CommandTemplate(List<String> arguments) : arguments = List.unmodifiable(arguments) {
    if (arguments.isEmpty || arguments.first.trim().isEmpty) {
      throw ConfigurationException('dispatcher.command must not be empty.');
    }
    for (final argument in arguments) {
      _fill(argument, (name) {
        if (!placeholders.contains(name)) {
          throw ConfigurationException(
            'dispatcher.command: unknown placeholder "{$name}" (known: ${placeholders.map((p) => '{$p}').join(', ')}).',
          );
        }
        return '';
      });
    }
  }

  /// Splits [command] into arguments like a POSIX shell would (whitespace,
  /// '…' and "…" quotes, backslash escapes) without running one: there are
  /// no pipes, variables or globs, so filled-in values can never inject.
  factory CommandTemplate.parse(String command) => CommandTemplate(splitWords(command));

  /// What a command may refer to: the item id and title, the worktree name,
  /// its absolute path and the absolute path of the backlog folder.
  static const placeholders = ['id', 'title', 'worktree', 'path', 'backlog'];

  final List<String> arguments;

  /// The arguments with placeholders replaced by [values] (keys from
  /// [placeholders]; a missing one becomes empty).
  List<String> render(Map<String, String> values) => [
    for (final argument in arguments) _fill(argument, (name) => values[name] ?? ''),
  ];

  @override
  String toString() => arguments.map(_quote).join(' ');

  static final _token = RegExp(r'\{\{|\}\}|\{([A-Za-z_]+)\}');

  static String _fill(String argument, String Function(String name) value) => argument.replaceAllMapped(
    _token,
    (match) => switch (match[0]) {
      '{{' => '{',
      '}}' => '}',
      _ => value(match[1]!),
    },
  );

  static String _quote(String argument) => RegExp(r'''^[A-Za-z0-9_./:={}@%+,-]+$''').hasMatch(argument)
      ? argument
      : "'${argument.replaceAll("'", r"'\''")}'";

  /// Shell-like word splitting of [command]; see [CommandTemplate.parse].
  static List<String> splitWords(String command) {
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
    if (quote != null) throw ConfigurationException('dispatcher.command: unterminated $quote quote.');
    if (inWord) words.add(word.toString());
    return words;
  }
}

/// The optional `dispatcher` section of `backlog.yaml`: which worktrees
/// agents may run in, how many at once, how to start one and whether to do
/// it automatically. Without the section there is no dispatcher.
final class DispatcherConfig {
  factory DispatcherConfig({
    required List<WorktreeDefinition> worktrees,
    required CommandTemplate command,
    DispatchMode mode = DispatchMode.manual,
    int? maxAgents,
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
    return DispatcherConfig._(List.unmodifiable(worktrees), command, mode, limit);
  }

  DispatcherConfig._(this.worktrees, this.command, this.mode, this.maxAgents);

  /// In order of preference: free work goes to the first free worktree.
  final List<WorktreeDefinition> worktrees;
  final CommandTemplate command;
  final DispatchMode mode;

  /// At most this many agents run at once (defaults to one per worktree;
  /// more than there are worktrees has no effect).
  final int maxAgents;

  WorktreeDefinition? worktree(String name) {
    for (final worktree in worktrees) {
      if (worktree.name == name) return worktree;
    }
    return null;
  }
}
