import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import 'config_draft.dart';

/// One listed worktree of a draft: [name] and [path] as written (a bare
/// name means `../<name>`).
final class WorktreeSetting {
  const WorktreeSetting(this.name, this.path);

  final String name;
  final String path;
}

/// Typed reads and edits of `dispatcher` in a `backlog.yaml` [draft] (§2):
/// mode, limits, listed worktrees, worktrees on demand, base branch and
/// agent profile. An empty input removes the key; the review checks the
/// whole section.
final class DispatcherSettings {
  DispatcherSettings(this.draft);

  final ConfigDraft draft;

  static const _key = 'dispatcher';

  /// Keys edited as one line of text, and those taking whole numbers.
  static const textKeys = {'repo', 'worktree_name', 'base'};
  static const numberKeys = {'max_agents', 'max_worktrees', 'cleanup_after_days'};

  /// Whether the file has a dispatcher section at all.
  bool get enabled => draft.valueAt([_key]) != null;

  String get mode => '${draft.valueAt([_key, 'mode']) ?? 'manual'}';

  void setMode(String mode) {
    if (mode != 'auto' && mode != 'manual') throw InvalidInputException('The mode is auto or manual, not "$mode".');
    draft.set([_key, 'mode'], mode);
  }

  /// The value of [key] under `dispatcher` as text, null when absent.
  String? text(String key) => switch (draft.valueAt([_key, key])) {
    null => null,
    final value => '$value',
  };

  void setText(String key, String input) {
    if (!textKeys.contains(key)) throw InvalidInputException('dispatcher.$key is not a text.');
    final value = input.trim();
    if (key == 'base' && value.startsWith('-')) throw InvalidInputException('The base must not start with "-".');
    if (key == 'worktree_name' && value.isNotEmpty && !value.contains('{n}')) {
      throw const InvalidInputException('The worktree name must contain {n}, e.g. {repo}-agent-{n}.');
    }
    _set(key, value.isEmpty ? null : value);
  }

  void setNumber(String key, String input) {
    if (!numberKeys.contains(key)) throw InvalidInputException('dispatcher.$key is not a number.');
    final text = input.trim();
    final number = int.tryParse(text);
    if (text.isNotEmpty && (number == null || number < 1)) {
      throw InvalidInputException('dispatcher.$key must be a whole number of at least 1, not "$text".');
    }
    _set(key, number);
  }

  /// The profile agents start with.
  String get agent => text('agent') ?? 'claude';

  /// The profiles to choose from: the built-in ones and those of
  /// `dispatcher.agents`.
  List<String> get profiles {
    final own = draft.valueAt([_key, 'agents']);
    return {...AgentProfile.builtIns.keys, if (own is Map) ...own.keys.map((key) => '$key')}.toList();
  }

  void setAgent(String name) {
    if (!profiles.contains(name)) throw InvalidInputException('There is no agent profile "$name".');
    _set('agent', name);
  }

  List<WorktreeSetting> get worktrees {
    final list = draft.valueAt([_key, 'worktrees']);
    if (list is! List) return const [];
    return [
      for (final entry in list)
        if (entry is Map)
          WorktreeSetting('${entry['name'] ?? ''}', '${entry['path'] ?? '../${entry['name'] ?? ''}'}')
        else
          WorktreeSetting('$entry', '../$entry'),
    ];
  }

  /// Lists worktree [name] at [path] (absolute or relative to the backlog
  /// folder; empty: `../<name>`, written as the bare name).
  void addWorktree(String name, {String path = ''}) {
    final id = name.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(id)) {
      throw InvalidInputException('A worktree name is letters, digits, ".", "_" and "-": "$id".');
    }
    if (worktrees.any((worktree) => worktree.name == id)) throw InvalidInputException('Worktree "$id" is listed.');
    final where = path.trim();
    final Object value = where.isEmpty || where == '../$id' ? id : {'name': id, 'path': where};
    if (draft.valueAt([_key, 'worktrees']) is List) {
      draft.insert([_key, 'worktrees'], worktrees.length, value);
    } else {
      draft.set([_key, 'worktrees'], [value]);
    }
  }

  void removeWorktree(int index) {
    _worktree(index);
    draft.remove([_key, 'worktrees', index]);
  }

  /// Moves listed worktree [index] to [path] (empty: `../<name>`).
  void setWorktreePath(int index, String path) {
    final worktree = _worktree(index);
    final where = path.trim();
    draft.set([
      _key,
      'worktrees',
      index,
    ], where.isEmpty || where == '../${worktree.name}' ? worktree.name : {'name': worktree.name, 'path': where});
  }

  WorktreeSetting _worktree(int index) {
    final all = worktrees;
    if (index < 0 || index >= all.length) throw InvalidInputException('There is no worktree ${index + 1}.');
    return all[index];
  }

  void _set(String key, Object? value) {
    if (value == null) {
      draft.remove([_key, key]);
    } else {
      draft.set([_key, key], value);
    }
  }
}
