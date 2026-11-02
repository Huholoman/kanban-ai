import '../../shared/errors.dart';
import 'dispatcher_config.dart';

/// How the `touches` of an item are estimated (`touches` in
/// `backlog.yaml`): a command — typically a cheap or local model — gets the
/// item's description and a map of the code repository and answers with
/// paths or globs, which a person then confirms or corrects.
final class TouchesConfig {
  TouchesConfig({required this.suggest, this.repo, this.timeout = const Duration(minutes: 2)}) {
    if (timeout <= Duration.zero) throw const ConfigurationException('touches.timeout must be positive.');
  }

  /// What `touches.suggest` may refer to: the item id and title, the
  /// absolute paths of the backlog folder and of the code repository, and
  /// the rendered prompt (without `{prompt}` it is the standard input).
  static const placeholders = ['id', 'title', 'backlog', 'repo', 'prompt'];

  /// The command that answers the prompt on its standard output.
  final CommandTemplate suggest;

  /// The code repository whose files make the map, absolute or relative to
  /// the backlog folder; null: `dispatcher.repo`, else the first dispatcher
  /// worktree, else the backlog folder.
  final String? repo;

  /// How long the command may take.
  final Duration timeout;

  /// Whether [suggest] gets the prompt as an argument (`{prompt}`), so that
  /// it does not need it on its standard input.
  bool get promptInArguments => suggest.render(const {'prompt': '\u0000'}).any((a) => a.contains('\u0000'));
}
