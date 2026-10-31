/// Base type of every failure the backlog reports to its callers.
///
/// Adapters (CLI, server, app) map the subtypes to exit codes, HTTP statuses
/// or UI messages; the core never prints anything itself.
sealed class BacklogException implements Exception {
  const BacklogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A referenced item, view or file does not exist.
final class NotFoundException extends BacklogException {
  const NotFoundException(super.message);
}

/// A shortened item reference matches more than one item.
final class AmbiguousReferenceException extends BacklogException {
  const AmbiguousReferenceException(super.message, this.candidates);

  final List<String> candidates;
}

/// The input violates the workflow or the item format.
final class InvalidInputException extends BacklogException {
  const InvalidInputException(super.message);
}

/// Another agent holds the claim on the item.
final class ClaimConflictException extends BacklogException {
  const ClaimConflictException(super.message);
}

/// `backlog.yaml` or a view definition is malformed.
final class ConfigurationException extends BacklogException {
  const ConfigurationException(super.message);
}

/// Something needed right now is not available (e.g. no free worktree for
/// an agent, or the worktree has uncommitted changes); trying later may work.
final class UnavailableException extends BacklogException {
  const UnavailableException(super.message);
}
