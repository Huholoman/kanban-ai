import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../backlog.dart';
import '../../items/application/field_change.dart';
import '../../items/domain/item.dart';
import '../../shared/errors.dart';

/// What [PullRequestOpener.open] did.
final class PullRequestOutcome {
  const PullRequestOutcome({
    required this.url,
    required this.created,
    required this.branch,
    required this.base,
    required this.remote,
  });

  /// The pull request's URL (also in the item's `pr` field).
  final String url;

  /// Whether it was opened now; false when it existed (the `pr` field was
  /// set, or `dispatcher.pr.find` found one) and the branch was only pushed.
  final bool created;
  final String branch;
  final String base;
  final String remote;
}

/// Turns an item's branch into a pull request (`dispatcher.pr`): pushes the
/// branch — only that branch, never the base, never forced — then, unless
/// the item already has one, runs the configured `create` command in the
/// worktree with the description on its standard input and writes the URL
/// from its output into the item's `pr` field. Running it again only pushes
/// (new commits reach the open pull request).
final class PullRequestOpener {
  PullRequestOpener({this.timeout = const Duration(minutes: 2), Map<String, String>? environment})
    : _environment = environment;

  /// How long `git push`, `create` and `find` may take each.
  final Duration timeout;
  final Map<String, String>? _environment;

  /// Opens (or updates) the pull request of item [reference] from the git
  /// worktree at [workingDirectory]. [description] is the pull request's
  /// text; without one a minimal one is made from the item and its commits.
  /// The branch is the item's `branch` field, else the one checked out.
  /// [force] replaces the remote branch after a rebase
  /// (`--force-with-lease`: only when it is still what was last fetched or
  /// pushed from here) — the item's own branch only, never the base.
  Future<PullRequestOutcome> open(
    Backlog backlog,
    String reference, {
    required String workingDirectory,
    String? description,
    bool force = false,
  }) async {
    final dispatcher = backlog.workflow.dispatcher;
    final config =
        dispatcher?.pr ??
        (throw const ConfigurationException(
          'This backlog opens no pull requests: backlog.yaml has no dispatcher.pr section.',
        ));
    final base = dispatcher!.base;
    final item = await backlog.items.get(reference);
    final branch = item.branch ?? await _currentBranch(workingDirectory);
    if (branch == base) {
      throw InvalidInputException('${item.id} is on the base branch $base; only an item\'s own branch is pushed.');
    }
    if (branch.startsWith('-') || branch.contains(RegExp(r'[\s:]'))) {
      throw InvalidInputException('"$branch" is not a branch name.');
    }
    final known = await _git(workingDirectory, ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch']);
    if (known.exitCode != 0) throw InvalidInputException('There is no branch $branch in $workingDirectory.');

    // An explicit refspec without "+": the branch under its own name, no
    // force (unless asked for, and then only with a lease), whatever
    // push.default or the branch's upstream say.
    final push = await _git(workingDirectory, [
      'push',
      '--set-upstream',
      if (force) '--force-with-lease=refs/heads/$branch',
      '--',
      config.remote,
      'refs/heads/$branch:refs/heads/$branch',
    ]);
    if (push.exitCode != 0) {
      final rejected = !force && '${push.stderr}'.contains(RegExp('non-fast-forward|fetch first|rejected'));
      throw UnavailableException(
        'git push ${config.remote} $branch failed: ${_lastLines('${push.stderr}')}'
        '${rejected ? ' (after a rebase, push with `backlog pr ${item.id} --force`)' : ''}',
      );
    }
    PullRequestOutcome outcome(String url, {required bool created}) =>
        PullRequestOutcome(url: url, created: created, branch: branch, base: base, remote: config.remote);

    if (item.pr case final existing? when existing.trim().isNotEmpty) return outcome(existing, created: false);
    final text =
        _withReference(description?.trim() ?? '', item) ??
        await _defaultDescription(workingDirectory, item, branch, base);
    final values = {
      'id': item.id.value,
      'title': item.title,
      'branch': branch,
      'base': base,
      'remote': config.remote,
      'description': text,
    };
    if (config.find case final find?) {
      final found = await _run(find.render(values), workingDirectory, label: 'dispatcher.pr.find');
      if (found.exitCode == 0) {
        if (config.urlIn(found.output) case final url?) {
          await _record(backlog, item, url);
          return outcome(url, created: false);
        }
      }
    }
    final created = await _run(
      config.create.render(values),
      workingDirectory,
      label: 'dispatcher.pr.create',
      input: text,
    );
    if (created.exitCode != 0) {
      throw UnavailableException(
        'Pushed $branch, but opening the pull request failed (exit code ${created.exitCode}): '
        '${_lastLines(created.output)}',
      );
    }
    final url = config.urlIn(created.output);
    if (url == null) {
      throw UnavailableException(
        'Pushed $branch and ran dispatcher.pr.create, but its output has no pull request URL '
        '(adjust dispatcher.pr.url_pattern, or set it with `backlog set ${item.id} pr=<url>`): '
        '${_lastLines(created.output)}',
      );
    }
    await _record(backlog, item, url);
    return outcome(url, created: true);
  }

  static Future<void> _record(Backlog backlog, Item item, String url) =>
      backlog.items.update(item.id.value, [FieldChange('pr', ChangeOp.set, url)]);

  /// [text] with a reference to the item appended unless it names it; null
  /// for an empty text.
  static String? _withReference(String text, Item item) {
    if (text.isEmpty) return null;
    return text.contains(item.id.value) ? text : '$text\n\nBacklog item: ${item.id}';
  }

  Future<String> _defaultDescription(String path, Item item, String branch, String base) async {
    final log = await _git(path, ['log', '--format=- %s', '$base..$branch']);
    final commits = log.exitCode == 0 ? '${log.stdout}'.trim() : '';
    return '${item.title}\n\nBacklog item: ${item.id}'
        '${commits.isEmpty ? '' : '\n\nCommits:\n$commits'}';
  }

  Future<String> _currentBranch(String path) async {
    final head = await _git(path, ['symbolic-ref', '--quiet', '--short', 'HEAD']);
    if (head.exitCode != 0) {
      throw InvalidInputException('$path is not on a branch, and the item has no branch field.');
    }
    return '${head.stdout}'.trim();
  }

  Future<ProcessResult> _git(String path, List<String> arguments) =>
      Process.run('git', arguments, workingDirectory: path, environment: _environment).timeout(timeout);

  /// Runs [command] (no shell) in [path] with [input] on its standard input;
  /// standard output and error together.
  Future<({int exitCode, String output})> _run(
    List<String> command,
    String path, {
    required String label,
    String input = '',
  }) async {
    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.skip(1).toList(),
        workingDirectory: path,
        environment: _environment,
      );
    } on ProcessException catch (error) {
      throw UnavailableException('$label: cannot run "${command.first}": ${error.message}');
    }
    final output = StringBuffer();
    final done = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(output.write),
    ]);
    try {
      process.stdin.write(input);
      await process.stdin.close();
    } on Object {
      // The command does not read its standard input; that is fine.
    }
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw UnavailableException('$label did not finish within ${timeout.inSeconds} s.');
    }
    await done;
    return (exitCode: exitCode, output: '$output');
  }

  static String _lastLines(String text, [int count = 5]) {
    final lines = LineSplitter.split(text.trim()).where((line) => line.trim().isNotEmpty).toList();
    return lines.length <= count ? lines.join(' | ') : lines.sublist(lines.length - count).join(' | ');
  }
}
