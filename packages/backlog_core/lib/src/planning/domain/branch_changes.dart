import 'review_state.dart';

/// Port: the files the branches of the code repository changed since they
/// forked from the base branch (`git diff base...branch`), so that the
/// `touches` of work in progress can be completed with what it really
/// changes.
abstract interface class BranchChanges {
  /// Branch name → paths relative to the repository root, for those of
  /// [branches] that exist in [heads] (the current branch heads) and differ
  /// from the base. Empty when there is no repository to ask.
  Future<Map<String, List<String>>> changedFiles(Map<String, BranchHead> heads, Iterable<String> branches);
}
