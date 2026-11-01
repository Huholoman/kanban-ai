import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../../items/application/field_change.dart';
import '../../items/domain/item_id.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../../workflow/domain/merge_config.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/action_run.dart';
import 'built_in_actions.dart';
import 'process_agent_launcher.dart';

/// The built-in action `merge` (`run: merge`, typically `on_enter: deploy`):
/// brings the item's branch into `dispatcher.base` the way
/// `dispatcher.merge` says, then marks the item done and cleans up.
///
/// - `local`: in the worktree that has the branch checked out (else a
///   temporary one next to the primary clone) the branch is rebased onto the
///   base when it does not contain it, `check` runs there, `push` pushes the
///   result to the remote's base (never forced), and the base is
///   fast-forwarded where it is checked out (usually the primary clone,
///   which must have no uncommitted changes to tracked files) — or, checked
///   out nowhere, its ref is moved.
/// - `pr`: `dispatcher.pr.merge` merges the item's pull request.
/// - `command`: `dispatcher.merge.command`; exit code 0 means merged.
///
/// **Success:** the item gets the first done status, and with `cleanup`
/// its branch, worktree and session are cleaned up ([MergeCleanup]). An
/// epic takes the items with work on its branch along; it is done itself
/// only when nothing under it remains, else it goes back like after a
/// failure, without its `pr` (`ClaimService.completeMerged`).
/// **An item on its epic's branch** with other unfinished items there is
/// not merged: it goes back with a note to deploy the epic.
/// **Failure** (a rebase conflict, a failing check, a refused merge or
/// push): nothing is left half done — a rebase is aborted and the branch
/// keeps its commits as before — the item goes back to the status it came
/// from (for a hook) and a comment says why and how to fix it; a comment
/// (not a note), so that the item's agent continues its session with it.
/// Problems of the setup (no primary clone, uncommitted changes there, no
/// pull request) only get a note: they are for a person.
final class MergeAction implements BuiltInAction {
  const MergeAction();

  @override
  String get name => 'merge';

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) async {
    final config = context.config;
    final merge = config.merge;
    final id = context.item.id;
    final branch = context.values['branch'] ?? 'agent/$id';
    final values = {
      ...context.values,
      'remote': merge.remote,
      'pr_number': PullRequestConfig.numberOf(context.item.item.pr ?? '') ?? '',
    };
    final git = _Git(context);
    String summary;
    try {
      if (branch == config.base) throw _Failed('$id is on the base branch ${config.base} itself.', setup: true);
      if (await context.backlog.claims.sharedEpicBranch(id, branch) case (:final epic, :final others)) {
        throw _Failed(
          'this work is on the branch $branch of the epic $epic together with ${others.join(', ')}; '
          'deploy the epic $epic instead (move it to ${context.action.onEnter ?? 'its merge status'}).',
          kind: _FailureKind.epic,
        );
      }
      summary = switch (merge.strategy) {
        MergeStrategy.local => await _local(context, git, branch, values),
        MergeStrategy.pr => await _pullRequest(context, values),
        MergeStrategy.command => await _command(context, values),
      };
    } on _Failed catch (failure) {
      final back = await _sendBack(context);
      await _report(context, failure, branch, back);
      return BuiltInActionResult(
        ok: false,
        summary: '${_sentence(failure.reason)}${back == null ? '' : '; $id went back to $back'}',
      );
    }
    final (:members, :remaining) = await context.backlog.claims.completeMerged(id, branch);
    final String state;
    if (remaining.isEmpty) {
      state = '$id is ${(await context.backlog.items.get(id.value)).status}';
    } else {
      final back = await _sendBack(context);
      state =
          'deployed ${members.length} item(s)${members.isEmpty ? '' : ' (${members.join(', ')})'}, '
          'remaining ${remaining.length} (${remaining.join(', ')}); $id stays open'
          '${back == null ? '' : ' and went back to $back'}, the next Implement epic starts a new branch from '
          '${config.base}';
    }
    final cleaned = <String>[if (remaining.isEmpty && members.isNotEmpty) 'with it ${members.join(', ')}'];
    if (merge.cleanup) {
      final repo = await primaryClone(
        context.config,
        context.backlogRoot,
        context.worktree == null ? null : context.path,
      );
      if (repo == null) {
        cleaned.add('no cleanup: the primary clone is unknown');
      } else {
        cleaned.addAll(
          await MergeCleanup(
            config: config,
            backlogRoot: context.backlogRoot,
            repo: repo,
            stateDir: context.stateDir,
            project: context.project,
            exec: (command, path) => context.capture(command, workingDirectory: path),
          ).run(id, branch),
        );
      }
    }
    return BuiltInActionResult(ok: true, summary: '$summary; $state${cleaned.map((c) => '; $c').join()}');
  }

  // ------------------------------------------------------------- strategies

  Future<String> _local(BuiltInActionContext context, _Git git, String branch, Map<String, String> values) async {
    final config = context.config;
    final merge = config.merge;
    final base = config.base;
    final id = context.item.id;
    final repo =
        await primaryClone(config, context.backlogRoot, context.worktree == null ? null : context.path) ??
        (throw _Failed(
          'cannot find the primary clone of the repository (set dispatcher.repo, or list a worktree).',
          setup: true,
        ));
    if (!await git.ok(['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'], repo)) {
      throw _Failed('there is no branch $branch in $repo.', setup: true);
    }
    final oldBase = await git.value(['rev-parse', '--verify', '--quiet', 'refs/heads/$base'], repo);
    if (oldBase == null) throw _Failed('there is no base branch $base in $repo.', setup: true);

    final checkedOut = await checkedOutBranches(repo, git.capture);
    final baseHome = checkedOut[base];
    if (baseHome != null && await git.trackedChanges(baseHome)) {
      throw _Failed(
        '$baseHome (where $base is checked out) has uncommitted changes to tracked files; commit or stash them '
        'and move $id to ${context.action.onEnter ?? 'its merge status'} again.',
        setup: true,
      );
    }
    final where = checkedOut[branch];
    final String work;
    String? temporary;
    if (where == null) {
      temporary = p.join(p.dirname(repo), '${p.basename(repo)}-merge-$id');
      final added = await git.capture(['worktree', 'add', '--quiet', temporary, branch], repo);
      if (!added.ok) throw _Failed('cannot add a worktree for $branch: ${_tail(added.output, 3)}', setup: true);
      work = temporary;
    } else if (context.worktree != null && samePath(where, context.path)) {
      work = where;
    } else {
      throw _Failed(
        '$branch is checked out in $where, which is not a free dispatcher worktree; switch it to another branch '
        'there and try again.',
        setup: true,
      );
    }

    final steps = <String>[];
    try {
      if (await git.trackedChanges(work)) {
        throw _Failed('$work has uncommitted changes to tracked files.', setup: true);
      }
      final original = (await git.value(['rev-parse', 'HEAD'], work))!;
      try {
        if (!await git.ok(['merge-base', '--is-ancestor', base, 'HEAD'], work)) {
          final rebase = await git.capture(['rebase', base], work);
          if (!rebase.ok) {
            final conflicts = await git.value(['diff', '--name-only', '--diff-filter=U'], work) ?? '';
            await git.capture(['rebase', '--abort'], work);
            final files = LineSplitter.split(conflicts).where((f) => f.isNotEmpty).toList();
            throw _Failed(
              files.isEmpty
                  ? 'rebasing $branch onto $base failed.'
                  : 'rebasing $branch onto $base conflicts in ${files.join(', ')}.',
              details: rebase.output,
              kind: _FailureKind.conflict,
            );
          }
          steps.add('rebased onto $base');
        }
        final checkValues = {...values, 'worktree': temporary == null ? context.worktree ?? '' : '', 'path': work};
        if (merge.check case final check?) {
          final result = await context.capture(check.render(checkValues), workingDirectory: work);
          if (!result.ok) {
            throw _Failed(
              'the check `${CommandTemplate.join(check.render(checkValues))}` failed with exit code '
              '${result.exitCode}${steps.isEmpty ? '' : ' (after the rebase onto $base)'}.',
              details: result.output,
              kind: _FailureKind.check,
            );
          }
          steps.add('checked');
        }
        final head = (await git.value(['rev-parse', 'HEAD'], work))!;
        if (merge.push) {
          final pushed = await git.capture(['push', '--', merge.remote, '$head:refs/heads/$base'], repo);
          if (!pushed.ok) {
            throw _Failed(
              'pushing to $base of ${merge.remote} was refused (it may have moved on: pull $base and try again).',
              details: pushed.output,
              kind: _FailureKind.refused,
            );
          }
        }
        final CommandOutput forward;
        if (baseHome != null) {
          forward = await git.capture(['merge', '--ff-only', '--quiet', head], baseHome);
        } else {
          forward = await git.capture(['update-ref', 'refs/heads/$base', head, oldBase], repo);
        }
        if (!forward.ok) {
          if (merge.push) {
            steps.add('but the local $base could not be fast-forwarded: ${_tail(forward.output, 2)}');
          } else {
            throw _Failed(
              'fast-forwarding $base to $branch failed.',
              details: forward.output,
              kind: _FailureKind.refused,
            );
          }
        }
        if (merge.push) steps.add('pushed $base to ${merge.remote}');
        context.log('merge: $base is now at $head');
      } on _Failed {
        // Leave the branch as it was: same commits, no half-done rebase.
        if (await git.value(['rev-parse', 'HEAD'], work) != original) {
          await git.capture(['reset', '--hard', '--quiet', original], work);
        }
        rethrow;
      }
    } finally {
      if (temporary != null) await git.capture(['worktree', 'remove', '--force', temporary], repo);
    }
    return 'merged $branch into $base (fast-forward${steps.isEmpty ? '' : ', ${steps.join(', ')}'})';
  }

  Future<String> _pullRequest(BuiltInActionContext context, Map<String, String> values) async {
    final id = context.item.id;
    final pr = context.item.item.pr?.trim() ?? '';
    final command = context.config.pr?.merge;
    if (command == null) throw _Failed('dispatcher.pr.merge is not configured.', setup: true);
    if (pr.isEmpty) {
      throw _Failed(
        '$id has no pull request to merge (its pr field is empty; `backlog pr $id` opens one).',
        setup: true,
      );
    }
    if (command.arguments.any((a) => a.contains('{pr_number}')) && values['pr_number']!.isEmpty) {
      throw _Failed('cannot tell the number of the pull request $pr.', setup: true);
    }
    final result = await context.capture(command.render(values));
    if (!result.ok) {
      throw _Failed(
        'merging the pull request $pr failed with exit code ${result.exitCode}.',
        details: result.output,
        kind: _FailureKind.refused,
      );
    }
    return 'merged the pull request $pr';
  }

  Future<String> _command(BuiltInActionContext context, Map<String, String> values) async {
    final command = context.config.merge.command!.render(values);
    final result = await context.capture(command);
    if (!result.ok) {
      throw _Failed(
        '`${CommandTemplate.join(command)}` failed with exit code ${result.exitCode}.',
        details: result.output,
        kind: _FailureKind.refused,
      );
    }
    return 'merged with `${CommandTemplate.join(command)}`';
  }

  // ---------------------------------------------------------------- failure

  /// Moves the item back to the status it came from when it entered the
  /// action's `on_enter` status (a hook) if that is an active one after the
  /// first (from the first, `in-progress`, an agent just fixed it), else to
  /// the closest such status before the hook's (the first active one when
  /// there is none); a button leaves it where it is. Returns the new status.
  Future<String?> _sendBack(BuiltInActionContext context) async {
    final hook = context.action.onEnter;
    if (context.trigger != ActionTrigger.onEnter || hook == null) return null;
    final id = context.item.id.value;
    final item = await context.backlog.items.get(id);
    if (item.status != hook) return null;
    final workflow = context.backlog.workflow;
    var target = context.from;
    // The dispatcher may have seen the item last before it got there (e.g.
    // in todo, when its agent set review just before a person moved it on).
    if (target == null ||
        target == hook ||
        target == workflow.activeStatus ||
        workflow.categoryOf(target) != StatusCategory.active) {
      final statuses = workflow.statuses.map((s) => s.id).toList();
      final before = [
        for (var i = statuses.indexOf(hook) - 1; i >= 0; i--)
          if (workflow.categoryOf(statuses[i]) == StatusCategory.active) statuses[i],
      ];
      target = before.firstWhereOrNull((s) => s != workflow.activeStatus) ?? before.firstOrNull;
    }
    if (target == null) return null;
    await context.backlog.items.update(id, [FieldChange('status', ChangeOp.set, target)]);
    return target;
  }

  Future<void> _report(BuiltInActionContext context, _Failed failure, String branch, String? back) async {
    final id = context.item.id;
    final config = context.config;
    final base = config.base;
    final strategy = config.merge.strategy;
    final text = StringBuffer('Merging $branch into $base (${strategy.name}) failed: ${failure.reason}');
    final details = _tail(
      LineSplitter.split(failure.details).where((line) => !line.startsWith('hint: ')).join('\n'),
      15,
      join: '\n',
    );
    if (details.isNotEmpty) {
      final fence = details.contains('```') ? '~~~~' : '```';
      text.write('\n\n${fence}text\n$details\n$fence');
    }
    final hook = context.trigger == ActionTrigger.onEnter ? context.action.onEnter : null;
    final again = hook == null ? 'run the action "${context.action.name}" again' : 'move it to $hook again';
    final upstream = strategy == MergeStrategy.local ? base : '${config.merge.remote}/$base';
    final check = config.merge.check == null
        ? 'run the project\'s checks'
        : 'run `${CommandTemplate.join(config.merge.check!.render(context.values))}`';
    // Every command must pass the agent's tool whitelist (`git *`, never
    // `git -…`); GIT_EDITOR=true lets `git rebase --continue` run headless.
    final steps = [
      if (strategy != MergeStrategy.local) '`git fetch ${config.merge.remote}`',
      '`git rebase $upstream` on $branch',
      'resolve the conflicts git reports, `git add <file>` for each resolved file, then `git rebase --continue` '
          '(repeat until the rebase is done; never `git rebase --abort` or `--skip`)',
      '$check and commit what it needs',
      if (config.pr != null) 'publish the branch with `backlog pr $id --force` (never `git push`)',
      if (hook == null)
        'leave $id in ${back ?? 'its status'}: do not change its status'
      else
        '`backlog set $id status=$hook` to merge it again — unless a person has to decide something (how to '
            'resolve a conflict, a check you cannot fix): then leave it in ${back ?? 'its status'} and ask with '
            '`backlog ask $id "…"`',
    ];
    final numbered = [for (final (i, step) in steps.indexed) '${i + 1}. $step'].join('\n');
    switch (failure.kind) {
      case _FailureKind.conflict || _FailureKind.refused || _FailureKind.check:
        text.write(
          '\n\nTo fix it, in the worktree of $branch:\n\n$numbered${hook == null ? '\n\nThen $again to merge it.' : ''}',
        );
      case _FailureKind.setup:
        text.write('\n\nNothing was merged; fix this and $again.');
      case _FailureKind.epic:
        text.write('\n\nNothing was merged.');
    }
    try {
      await context.backlog.items.comment(
        id.value,
        author: ProcessAgentLauncher.noteAuthor,
        text: '$text',
        note: failure.kind == _FailureKind.setup || failure.kind == _FailureKind.epic,
      );
    } on BacklogException catch (error) {
      context.log('merge: could not comment on $id: ${error.message}');
    }
  }

  // ---------------------------------------------------------------- helpers

  /// The primary clone of the repository: `dispatcher.repo`, else the main
  /// worktree of [worktreePath] or of the first listed worktree that is a
  /// git worktree (from `git rev-parse --git-common-dir`); null when none
  /// is found.
  static Future<String?> primaryClone(DispatcherConfig config, String backlogRoot, String? worktreePath) async {
    if (config.newWorktrees case final added?) return added.resolveRepo(backlogRoot);
    for (final path in [?worktreePath, for (final w in config.worktrees) w.resolvePath(backlogRoot)]) {
      if (!await Directory(path).exists()) continue;
      try {
        final common = await Process.run('git', [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ], workingDirectory: path);
        if (common.exitCode != 0) continue;
        final dir = '${common.stdout}'.trim();
        if (p.basename(dir) == '.git') return p.dirname(dir);
      } on ProcessException {
        return null;
      }
    }
    return null;
  }

  /// Branch name → path of the worktree that has it checked out, from
  /// `git worktree list --porcelain` in [repo].
  static Future<Map<String, String>> checkedOutBranches(
    String repo,
    Future<CommandOutput> Function(List<String> arguments, String path) git,
  ) async {
    final list = await git(['worktree', 'list', '--porcelain'], repo);
    final branches = <String, String>{};
    String? path;
    for (final line in LineSplitter.split(list.output)) {
      if (line.startsWith('worktree ')) path = line.substring('worktree '.length);
      if (line.startsWith('branch refs/heads/') && path != null) {
        branches[line.substring('branch refs/heads/'.length)] = path;
      }
    }
    return branches;
  }

  /// Whether [a] and [b] are the same folder (symbolic links resolved).
  static bool samePath(String a, String b) {
    String real(String path) {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return p.normalize(p.absolute(path));
      }
    }

    return p.equals(real(a), real(b));
  }

  static String _sentence(String text) => text.endsWith('.') ? text.substring(0, text.length - 1) : text;

  static String _tail(String text, int count, {String join = ' | '}) {
    final lines = LineSplitter.split(text.trim()).where((line) => line.trim().isNotEmpty).toList();
    return (lines.length <= count ? lines : lines.sublist(lines.length - count)).join(join);
  }
}

/// Cleans up after an item's branch was merged: the worktree that has it
/// checked out is removed when the dispatcher created it, switched to the
/// base (detached) when it is a listed one, and left alone otherwise (or
/// with uncommitted changes or untracked files); then the branch is deleted
/// when that loses nothing — it is contained in the base, or it is exactly
/// what was pushed to the remote (the pull request) — and the item's agent
/// session is dropped (its last run stays, without the session id).
final class MergeCleanup {
  MergeCleanup({
    required this.config,
    required this.backlogRoot,
    required this.repo,
    required this.exec,
    this.stateDir,
    this.project,
  });

  final DispatcherConfig config;
  final String backlogRoot;

  /// The primary clone.
  final String repo;
  final String? stateDir;
  final String? project;

  /// Runs `git` with these arguments in a folder.
  final Future<CommandOutput> Function(List<String> command, String path) exec;

  Future<CommandOutput> _git(List<String> arguments, String path) => exec(['git', ...arguments], path);

  /// What was cleaned up (or kept, and why), one entry per step.
  Future<List<String>> run(ItemId id, String branch) async {
    final done = <String>[];
    final base = config.base;
    if (branch == base) return done;
    final where = (await MergeAction.checkedOutBranches(repo, _git))[branch];
    var free = where == null;
    if (where != null) {
      final name = p.basename(where);
      final dirty = (await _git(['status', '--porcelain'], where)).output.trim().isNotEmpty;
      final created = await _createdRecord(where);
      final listed = config.worktrees.any((w) => MergeAction.samePath(w.resolvePath(backlogRoot), where));
      if (MergeAction.samePath(where, repo)) {
        done.add('kept $branch: it is checked out in the primary clone');
      } else if (dirty) {
        done.add('kept the worktree $name: it has uncommitted changes or untracked files');
      } else if (created != null) {
        final removed = await _git(['worktree', 'remove', where], repo);
        if (removed.ok) {
          await created.delete();
          done.add('removed the worktree $name');
          free = true;
        } else {
          done.add('could not remove the worktree $name');
        }
      } else if (listed) {
        if ((await _git(['checkout', '--quiet', '--detach', base], where)).ok) {
          done.add('$name is back on $base');
          free = true;
        }
      } else {
        done.add('kept $branch: it is checked out in $where');
      }
    }
    if (free) {
      final tip = (await _git(['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'], repo)).output.trim();
      final pushed = (await _git([
        'rev-parse',
        '--verify',
        '--quiet',
        'refs/remotes/${config.merge.remote}/$branch',
      ], repo)).output.trim();
      if (tip.isNotEmpty) {
        final merged = (await _git(['merge-base', '--is-ancestor', tip, 'refs/heads/$base'], repo)).ok;
        if (merged || tip == pushed) {
          if ((await _git(['branch', '-D', '--', branch], repo)).ok) done.add('deleted the branch $branch');
        } else {
          done.add('kept the branch $branch: it has commits that are neither in $base nor pushed');
        }
      }
    }
    if (await _dropSession(id)) done.add('dropped the agent session');
    return done;
  }

  /// The record of the worktree at [path] when the dispatcher created it.
  Future<File?> _createdRecord(String path) async {
    final state = stateDir, name = project;
    if (state == null || name == null) return null;
    final dir = Directory(p.join(state, 'worktrees', name));
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entry.readAsString());
        if (json is Map && json['path'] is String && MergeAction.samePath(json['path'] as String, path)) return entry;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// Removes the session id from the item's last run, so that nothing
  /// continues it; false when there was none.
  Future<bool> _dropSession(ItemId id) async {
    final state = stateDir, name = project;
    if (state == null || name == null) return false;
    final file = File(p.join(state, 'agents', name, '$id.last.json'));
    try {
      final json = (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
      if (json['session_id'] == null) return false;
      json['session_id'] = null;
      json['session_dropped'] = 'merged';
      await file.writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }
}

enum _FailureKind { conflict, check, refused, setup, epic }

final class _Failed implements Exception {
  _Failed(this.reason, {this.details = '', _FailureKind? kind, bool setup = false})
    : kind = kind ?? (setup ? _FailureKind.setup : _FailureKind.refused);

  final String reason;
  final String details;
  final _FailureKind kind;
}

/// Git through the action's log.
final class _Git {
  _Git(this._context);

  final BuiltInActionContext _context;

  Future<CommandOutput> capture(List<String> arguments, String path) =>
      _context.capture(['git', ...arguments], workingDirectory: path);

  Future<bool> ok(List<String> arguments, String path) async => (await capture(arguments, path)).ok;

  /// The trimmed output, or null when git failed.
  Future<String?> value(List<String> arguments, String path) async {
    final result = await capture(arguments, path);
    return result.ok ? result.output.trim() : null;
  }

  Future<bool> trackedChanges(String path) async =>
      (await capture(['status', '--porcelain', '--untracked-files=no'], path)).output.trim().isNotEmpty;
}
