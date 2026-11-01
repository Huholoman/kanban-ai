import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/preview.dart';
import 'built_in_actions.dart';
import 'merge_action.dart';

/// The built-in action `preview` (`run: preview`, a button such as "Deploy
/// locally" on items in review): runs the board from the item's branch
/// rebased onto the base, without merging anything, the way
/// `dispatcher.preview` says.
///
/// In the helper worktree next to the primary clone (`{repo}-preview`,
/// added on first use) a copy of the branch is checked out (detached: the
/// branch and its pull request stay as they are) and rebased onto
/// `dispatcher.base`; then `check` and `install` run there. With `server`
/// the board's server restarts from that program once the action has ended
/// (its result is in the item's discussion by then); the server remembers
/// the preview ([PreviewState]) until "Back to main" ([LocalPreview]).
///
/// **Failure** (a rebase conflict, a failing check or install, a server
/// program that does not run): the rebase is aborted, the running server
/// and the current preview stay as they are and the action's note says why.
/// Only one preview is prepared at a time; a new one replaces the previous.
final class PreviewAction implements BuiltInAction {
  const PreviewAction();

  @override
  String get name => 'preview';

  /// A preview being prepared (server-wide: they share the worktree).
  static bool _busy = false;

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) async {
    if (_busy) {
      return const BuiltInActionResult(ok: false, summary: 'another preview is being prepared; try again when it ends');
    }
    _busy = true;
    try {
      return await _run(context);
    } on _Failed catch (failure) {
      return BuiltInActionResult(ok: false, summary: 'deploying the preview failed: ${failure.reason}');
    } finally {
      _busy = false;
    }
  }

  Future<BuiltInActionResult> _run(BuiltInActionContext context) async {
    final config = context.config;
    final preview = config.preview;
    final base = config.base;
    final id = context.item.id;
    final branch = context.values['branch'] ?? 'agent/$id';
    Future<CommandOutput> git(List<String> arguments, String path) =>
        context.capture(['git', ...arguments], workingDirectory: path);
    Future<String?> value(List<String> arguments, String path) async {
      final result = await git(arguments, path);
      return result.ok ? result.output.trim() : null;
    }

    final repo =
        await MergeAction.primaryClone(config, context.backlogRoot, context.worktree == null ? null : context.path) ??
        (throw _Failed('cannot find the primary clone of the repository (set dispatcher.repo, or list a worktree)'));
    if (await value(['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'], repo) == null) {
      throw _Failed('there is no branch $branch in $repo');
    }
    if (await value(['rev-parse', '--verify', '--quiet', 'refs/heads/$base'], repo) == null) {
      throw _Failed('there is no base branch $base in $repo');
    }
    final server = context.server;
    final program = preview.server;
    if (program != null) {
      if (server == null) throw _Failed('this server cannot restart itself (dispatcher.preview.server is $program)');
      if (await server.problemWith(program) case final problem?) throw _Failed(problem);
    }

    final work = p.join(p.dirname(repo), preview.worktreeName(p.basename(repo)));
    if (await Directory(work).exists()) {
      // Whatever an earlier preview left: an unfinished rebase, changes.
      if (await Directory(p.join(work, '.git')).exists() || await File(p.join(work, '.git')).exists()) {
        await git(['rebase', '--abort'], work);
      }
      final checkout = await git(['checkout', '--quiet', '--force', '--detach', branch], work);
      if (!checkout.ok) throw _Failed('cannot check out $branch in $work: ${_tail(checkout.output, 3)}');
    } else {
      final added = await git(['worktree', 'add', '--quiet', '--detach', work, branch], repo);
      if (!added.ok) throw _Failed('cannot add the preview worktree $work: ${_tail(added.output, 3)}');
    }

    final steps = <String>[];
    if (!(await git(['merge-base', '--is-ancestor', base, 'HEAD'], work)).ok) {
      final rebase = await git(['rebase', base], work);
      if (!rebase.ok) {
        final conflicts = await value(['diff', '--name-only', '--diff-filter=U'], work) ?? '';
        await git(['rebase', '--abort'], work);
        final files = LineSplitter.split(conflicts).where((f) => f.isNotEmpty).toList();
        throw _Failed(
          files.isEmpty
              ? 'rebasing $branch onto $base failed'
              : 'conflict in ${files.join(', ')} (rebasing onto $base)',
        );
      }
      steps.add('rebased onto $base');
    }
    final commit = (await value(['rev-parse', 'HEAD'], work)) ?? (throw _Failed('cannot read the commit in $work'));
    final values = {
      'id': id.value,
      'title': context.item.item.title,
      'branch': branch,
      'base': base,
      'path': work,
      'repo': repo,
      'backlog': context.backlogRoot,
    };
    for (final (step, command) in [('check', preview.check), ('install', preview.install)]) {
      if (command == null) continue;
      final arguments = command.render(values);
      final result = await context.capture(arguments, workingDirectory: work);
      if (!result.ok) {
        throw _Failed('the $step `${CommandTemplate.join(arguments)}` failed with exit code ${result.exitCode}');
      }
      steps.add(step == 'check' ? 'checked' : 'installed');
    }

    final short = commit.length > 12 ? commit.substring(0, 12) : commit;
    final built = '$branch at $short${steps.isEmpty ? '' : ' (${steps.join(', ')})'}';
    if (program == null || server == null) {
      return BuiltInActionResult(
        ok: true,
        summary:
            'prepared the preview of $id: $built in $work; the server does not restart '
            '(dispatcher.preview.server is not set)',
      );
    }
    final stateDir = context.stateDir;
    final store = stateDir == null ? null : FilePreviewStore(stateDir);
    final previous = await store?.read();
    final state = PreviewState(
      project: context.project ?? '',
      item: id.value,
      title: context.item.item.title,
      branch: branch,
      commit: commit,
      base: base,
      since: DateTime.now().toUtc(),
      server: program,
      mainServer: previous != null && server.preview == previous.commit
          ? previous.mainServer
          : preview.mainServer ?? server.program,
    );
    await store?.write(state);
    return BuiltInActionResult(
      ok: true,
      summary: 'deployed the preview of $id: $built; the server restarts as $program',
      then: () async {
        try {
          await server.restart(program, preview: commit);
        } catch (error) {
          // Still the old server: it keeps running what it ran before.
          if (previous == null) {
            await store?.clear();
          } else {
            await store?.write(previous);
          }
          context.log('preview: restarting the server as $program failed: $error');
        }
      },
    );
  }

  static String _tail(String text, int count) {
    final lines = LineSplitter.split(text.trim()).where((line) => line.trim().isNotEmpty).toList();
    return (lines.length <= count ? lines : lines.sublist(lines.length - count)).join(' | ');
  }
}

final class _Failed implements Exception {
  _Failed(this.reason);

  final String reason;
}

/// The current preview in `preview.json` of the dispatcher's state folder.
final class FilePreviewStore implements PreviewStore {
  FilePreviewStore(String stateDir) : file = File(p.join(stateDir, 'preview.json'));

  final File file;

  @override
  Future<PreviewState?> read() async {
    try {
      return PreviewState.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
    } on FileSystemException {
      return null;
    } on Object {
      return null; // unreadable: as if there were none
    }
  }

  @override
  Future<void> write(PreviewState state) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n');
    await temp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// The server's local preview, for the board: what runs ([current]) and
/// "Back to main" ([backToMain]).
final class LocalPreview {
  LocalPreview({required this.store, this.server});

  final PreviewStore store;

  /// Null when this server cannot restart itself.
  final ServerControl? server;

  /// The preview this server runs; null when it runs its main build (also
  /// when the record is of a preview this server was not started for: it
  /// was started by hand since, or it is another server).
  Future<PreviewState?> current() async {
    final state = await store.read();
    if (state == null || server?.preview != state.commit) return null;
    return state;
  }

  /// Ends the preview: forgets it and restarts the server as its main
  /// program. Returns the ended preview; the restart follows after [delay]
  /// (time to answer the request).
  Future<PreviewState> backToMain({Duration delay = const Duration(milliseconds: 300)}) async {
    final state = await current() ?? (throw const InvalidInputException('No preview runs.'));
    final server = this.server ?? (throw const UnavailableException('This server cannot restart itself.'));
    if (await server.problemWith(state.mainServer) case final problem?) throw UnavailableException(problem);
    await store.clear();
    Future<void>.delayed(delay, () async {
      try {
        await server.restart(state.mainServer);
      } catch (_) {
        await store.write(state); // still the preview
      }
    }).ignore();
    return state;
  }
}
