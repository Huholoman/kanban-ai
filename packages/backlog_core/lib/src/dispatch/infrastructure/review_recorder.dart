import 'dart:async';
import 'dart:io';

import '../../backlog.dart';
import '../../items/domain/discussion.dart';
import '../../items/domain/item.dart';
import '../../shared/errors.dart';

/// What [ReviewRecorder.record] did.
final class ReviewOutcome {
  const ReviewOutcome({required this.item, required this.comment});

  /// The item with the review in its discussion.
  final Item item;

  /// The review comment as written.
  final Comment comment;
}

/// Records the verdict of a review of an item's work (`backlog review`): a
/// review comment in the item's discussion that names the commit it looked
/// at — the head of the item's branch, read from git in the working
/// directory — so that later commits make it outdated.
final class ReviewRecorder {
  ReviewRecorder({this.timeout = const Duration(minutes: 2), Map<String, String>? environment})
    : _environment = environment;

  /// How long a git call may take.
  final Duration timeout;
  final Map<String, String>? _environment;

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
    return ReviewOutcome(item: updated, comment: updated.discussion.lastReview!);
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
