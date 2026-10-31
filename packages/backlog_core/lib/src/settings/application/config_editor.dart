import '../../shared/errors.dart';
import '../domain/config_draft.dart';
import '../domain/config_file.dart';

/// Use cases of editing one configuration file: open a [ConfigDraft],
/// check it, save it. Adapters (the `backlog config` TUI, later the API)
/// build their pages on top; the file is only written by [save].
final class ConfigEditor {
  ConfigEditor({required this.scope, required ConfigFile file, required ConfigValidator validate})
    : _file = file,
      _validate = validate;

  final ConfigScope scope;
  final ConfigFile _file;
  final ConfigValidator _validate;

  String get location => _file.location;

  /// A draft of the file as it is now ('' when it does not exist yet).
  Future<ConfigDraft> open() async => ConfigDraft(await _file.read() ?? '');

  /// Why [draft] cannot be saved, or null when it is valid.
  String? problem(ConfigDraft draft) {
    try {
      _validate(draft.text);
      return null;
    } on BacklogException catch (e) {
      return e.message;
    }
  }

  /// Writes [draft] and returns a fresh draft of the saved text. Throws
  /// [ConfigurationException] when it is invalid and [UnavailableException]
  /// when the file changed since the draft was opened (nothing is written
  /// then). An unchanged draft writes nothing.
  Future<ConfigDraft> save(ConfigDraft draft) async {
    if (!draft.changed) return draft;
    if (problem(draft) case final problem?) throw ConfigurationException(problem);
    if ((await _file.read() ?? '') != draft.original) {
      throw UnavailableException('$location changed since it was opened; open it again to see the change.');
    }
    await _file.write(draft.text);
    return ConfigDraft(draft.text);
  }
}
