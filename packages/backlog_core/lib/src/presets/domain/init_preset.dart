/// What `backlog init` writes: a `backlog.yaml`, the saved views and,
/// optionally, a guide for the repository's `CLAUDE.md` / `AGENTS.md`.
///
/// The texts may contain the placeholders [placeholders] (`${prefix}`,
/// `${project}`, `${repo}`, `${repo_name}`), filled by [render]; anything
/// else, such as the dispatcher's own `{id}`, stays as it is.
final class InitPreset {
  const InitPreset({
    required this.name,
    required this.description,
    required this.config,
    required this.views,
    this.agentsGuide,
    this.source = builtIn,
  });

  /// [source] of the presets that come with kanban-ai.
  static const builtIn = 'built-in';

  /// The placeholders [render] replaces: the id prefix, the project's name,
  /// the code repository relative to the backlog folder and its folder name.
  static const placeholders = ['prefix', 'project', 'repo', 'repo_name'];

  final String name;

  /// One line for `backlog init --list-presets`.
  final String description;

  /// The `backlog.yaml` template.
  final String config;

  /// View id → its YAML template (`views/<id>.yaml`).
  final Map<String, String> views;

  /// Markdown for the repository's `CLAUDE.md` / `AGENTS.md` (the rules of
  /// working with the backlog), or null.
  final String? agentsGuide;

  /// [builtIn] or the folder (or backlog) it was read from.
  final String source;

  /// The preset with its placeholders replaced by [values].
  InitPreset render(Map<String, String> values) {
    String fill(String text) =>
        text.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (match) => values[match.group(1)!] ?? match.group(0)!);
    return InitPreset(
      name: name,
      description: description,
      config: fill(config),
      views: {for (final MapEntry(:key, :value) in views.entries) key: fill(value)},
      agentsGuide: agentsGuide == null ? null : fill(agentsGuide!),
      source: source,
    );
  }
}
