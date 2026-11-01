import '../../shared/errors.dart';
import 'dispatcher_config.dart';

/// `dispatcher.preview`: how the built-in action `preview` (a button
/// "Deploy locally" on items in review) prepares a preview of an item's
/// branch on this machine and runs the board from it.
///
/// A copy of the branch (a detached HEAD, the branch itself never moves) is
/// rebased onto `dispatcher.base` in the helper worktree [worktree] next to
/// the primary clone, then [check] and [install] run there, and with
/// [server] the board's server restarts from the new build. [mainServer] is
/// what "Back to main" restarts it with.
final class PreviewConfig {
  PreviewConfig({String? worktree, this.check, this.install, this.server, this.mainServer})
    : worktree = TextTemplate(
        worktree ?? defaultWorktree,
        known: const ['repo'],
        label: 'dispatcher.preview.worktree',
      ) {
    final example = this.worktree.render({'repo': 'repo'});
    if (example.isEmpty || example.contains('/') || example.startsWith('.') || example.startsWith('-')) {
      throw ConfigurationException(
        'dispatcher.preview.worktree gives "$example", which is not a folder name next to the primary clone.',
      );
    }
    if (example == 'repo') {
      throw const ConfigurationException(
        'dispatcher.preview.worktree must not be the primary clone itself ("{repo}"); e.g. "{repo}-preview".',
      );
    }
    for (final (key, program) in [('server', server), ('main_server', mainServer)]) {
      if (program != null && (program.trim().isEmpty || program != program.trim())) {
        throw ConfigurationException('dispatcher.preview.$key must be a program name or path.');
      }
    }
  }

  static const defaultWorktree = '{repo}-preview';

  /// What [check] and [install] may refer to: the item, its branch, the
  /// base, the preview worktree (`{path}`), the primary clone and the
  /// backlog folder.
  static const placeholders = ['id', 'title', 'branch', 'base', 'path', 'repo', 'backlog'];

  /// The folder name of the helper worktree, next to the primary clone;
  /// `{repo}` is the clone's folder name.
  final TextTemplate worktree;

  /// Runs after the rebase in the preview worktree; the preview stops when
  /// it fails (e.g. `mise run check`).
  final CommandTemplate? check;

  /// Builds and installs the preview (e.g. `mise run install-dev`).
  final CommandTemplate? install;

  /// The server program to restart the board with after [install] (e.g.
  /// `backlog-server-dev`): it starts with the running server's arguments
  /// and environment. Null: the server does not restart.
  final String? server;

  /// The server program "Back to main" restarts the board with (e.g.
  /// `backlog-server`); null: the program the server was started as.
  final String? mainServer;

  /// The folder name of the preview worktree for the primary clone named
  /// [repoName].
  String worktreeName(String repoName) => worktree.render({'repo': repoName});
}
