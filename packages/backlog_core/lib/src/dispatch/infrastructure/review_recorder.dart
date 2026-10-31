import 'dart:async';
import 'dart:io';

import '../../backlog.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/dispatcher_config.dart';
import 'pull_request_opener.dart';

/// What [ReviewRecorder.record] did.
final class ReviewOutcome {
  const ReviewOutcome({required this.item, required this.comment, this.posted, this.postError});

  /// The item with the review in its discussion.
  final Item item;

  /// The review comment as written.
  final Comment comment;

  /// The pull request the review was posted to (`dispatcher.pr.review`);
  /// null when it was not posted.
  final String? posted;

  /// Why posting it failed (also a note in the discussion); null when it
  /// was posted or not tried (no `dispatcher.pr.review`, or no `pr`).
  final String? postError;
}

/// Records the verdict of a review of an item's work (`backlog review`): a
/// review comment in the item's discussion that names the commit it looked
/// at — the head of the item's branch, read from git in the working
/// directory — so that later commits make it outdated. With
/// `dispatcher.pr.review` and a pull request in the item's `pr` field the
/// review is also posted there (best effort: a failure is a note).
final class ReviewRecorder {
  ReviewRecorder({this.timeout = const Duration(minutes: 2), Map<String, String>? environment})
    : _environment = environment,
      _commands = PullRequestOpener(timeout: timeout, environment: environment);

  /// Who writes the note when posting to the pull request fails.
  static const noteAuthor = 'kanban-ai';

  /// How long a git call may take.
  final Duration timeout;
  final Map<String, String>? _environment;
  final PullRequestOpener _commands;

  /// Adds the review [text] with [verdict] by [author] to item [reference].
  /// [commit] (an id or anything git resolves, e.g. `HEAD`) is the reviewed
  /// commit; without it the head of the item's branch (its `branch` field,
  /// else `agent/<id>`) in [workingDirectory] is used, and none when git
  /// does not know the branch there. An empty text of an `ok` review
  /// becomes "No findings."; a review asking for changes needs one.
  Future<ReviewOutcome> record(
    Backlog backlog,
    String reference, {
    required String author,
    required ReviewVerdict verdict,
    required String text,
    required String workingDirectory,
    String? commit,
  }) async {
    final item = await backlog.items.get(reference);
    var body = text.trim();
    if (body.isEmpty) {
      if (verdict == ReviewVerdict.changes) {
        throw const InvalidInputException('A review asking for changes needs its findings.');
      }
      body = 'No findings.';
    }
    final String? reviewed;
    if (commit != null && commit.trim().isNotEmpty) {
      reviewed =
          await _resolve(workingDirectory, commit.trim()) ??
          (RegExp(r'^[0-9a-fA-F]{4,40}$').hasMatch(commit.trim())
              ? commit.trim()
              : throw InvalidInputException('git does not know the commit "$commit" in $workingDirectory.'));
    } else {
      final branch = item.branch?.trim();
      reviewed = await _resolve(
        workingDirectory,
        'refs/heads/${branch == null || branch.isEmpty ? 'agent/${item.id}' : branch}',
      );
    }
    final updated = await backlog.items.comment(
      item.id.value,
      author: author,
      text: body,
      review: verdict,
      commit: reviewed == null ? null : _short(reviewed),
    );
    final comment = updated.discussion.lastReview!;
    final dispatcher = backlog.workflow.dispatcher;
    final post = dispatcher?.pr?.review;
    final pr = updated.pr?.trim() ?? '';
    if (post == null || pr.isEmpty) return ReviewOutcome(item: updated, comment: comment);
    try {
      await _post(post, dispatcher!, updated, comment, pr, workingDirectory);
      return ReviewOutcome(item: updated, comment: comment, posted: pr);
    } on BacklogException catch (error) {
      final note = await backlog.items.comment(
        updated.id.value,
        author: noteAuthor,
        text: 'Could not post the review of ${comment.author} to the pull request $pr: ${error.message}',
        note: true,
      );
      return ReviewOutcome(item: note, comment: comment, postError: error.message);
    }
  }

  /// Runs `dispatcher.pr.review` in [path] with the review as its standard
  /// input (and `{body}`).
  Future<void> _post(
    CommandTemplate post,
    DispatcherConfig config,
    Item item,
    Comment review,
    String pr,
    String path,
  ) async {
    final verdict = review.review == ReviewVerdict.ok ? 'nothing to change' : 'changes requested';
    final body =
        '**Review** by ${review.author}${review.commit == null ? '' : ' of ${review.commit}'}: $verdict\n\n'
        '${review.text}\n\n'
        '_Backlog item ${item.id}. This review approves nothing; a person decides._\n';
    final number = PullRequestConfig.numberOf(pr);
    if (number == null && post.arguments.any((argument) => argument.contains('{pr_number}'))) {
      throw UnavailableException('there is no pull request number in "$pr".');
    }
    final branch = item.branch?.trim();
    final command = post.render({
      'id': item.id.value,
      'title': item.title,
      'branch': branch == null || branch.isEmpty ? 'agent/${item.id}' : branch,
      'base': config.base,
      'remote': config.pr!.remote,
      'pr': pr,
      'pr_number': number ?? '',
      'verdict': review.review!.name,
      'body': body,
    });
    final result = await _commands.runCommand(command, path, label: 'dispatcher.pr.review', input: body);
    if (result.exitCode != 0) {
      throw UnavailableException(
        'dispatcher.pr.review exited with code ${result.exitCode}: ${PullRequestOpener.lastLines(result.output)}',
      );
    }
  }

  static String _short(String commit) => commit.length > 12 ? commit.substring(0, 12) : commit;

  /// The commit id [revision] names in the git repository at [path]; null
  /// when git does not know it or cannot run.
  Future<String?> _resolve(String path, String revision) async {
    if (revision.startsWith('-')) return null;
    try {
      final result = await Process.run(
        'git',
        ['rev-parse', '--verify', '--quiet', '$revision^{commit}'],
        workingDirectory: path,
        environment: _environment,
      ).timeout(timeout);
      final id = '${result.stdout}'.trim();
      return result.exitCode == 0 && id.isNotEmpty ? id.toLowerCase() : null;
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
