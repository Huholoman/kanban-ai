enum Severity { error, warning }

/// One problem found in the backlog.
final class LintIssue {
  const LintIssue(this.severity, this.code, this.message, {this.item, this.location});

  final Severity severity;

  /// Stable machine-readable kind, e.g. `dangling-reference`.
  final String code;
  final String message;
  final String? item;
  final String? location;

  @override
  String toString() => '${severity.name} [$code] ${item == null ? '' : '$item: '}$message';
}
