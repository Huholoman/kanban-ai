enum Severity { error, warning }

/// One problem found in the backlog.
final class LintIssue {
  const LintIssue(this.severity, this.code, this.message, {this.item, this.location, this.field, this.value});

  final Severity severity;

  /// Stable machine-readable kind, e.g. `dangling-reference`.
  final String code;
  final String message;
  final String? item;
  final String? location;

  /// The front-matter field at fault (`status`, `depends_on`, …), for fixes.
  final String? field;

  /// The value at fault in [field] (the unknown status, the missing id).
  final String? value;

  @override
  String toString() => '${severity.name} [$code] ${item == null ? '' : '$item: '}$message';
}
