/// Whose configuration a file holds: this machine's (the project registry,
/// server settings) or one project's (`backlog.yaml`).
enum ConfigScope { global, project }

/// One configuration file as text (a port; the file adapter is in
/// infrastructure).
abstract interface class ConfigFile {
  /// Where the file lives, for messages.
  String get location;

  /// The content; null when the file does not exist.
  Future<String?> read();

  /// Replaces the content (atomically, so readers never see half a file).
  Future<void> write(String content);
}

/// Throws a `ConfigurationException` when [source] is not a valid
/// configuration of its kind.
typedef ConfigValidator = void Function(String source);
