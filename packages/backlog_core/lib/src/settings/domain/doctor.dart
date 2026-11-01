/// How a finding of the doctor turned out.
enum DoctorLevel { ok, info, warning, error }

/// One thing the doctor looked at: what ([subject]) and what it found.
final class DoctorFinding {
  const DoctorFinding(this.level, this.subject, this.detail);

  final DoctorLevel level;
  final String subject;
  final String detail;
}

/// A group of findings (tools, server, registry, worktrees).
final class DoctorSection {
  const DoctorSection(this.title, this.findings);

  final String title;
  final List<DoctorFinding> findings;

  /// The worst level in the section ([DoctorLevel.ok] when empty).
  DoctorLevel get level =>
      findings.fold(DoctorLevel.ok, (worst, finding) => finding.level.index > worst.index ? finding.level : worst);
}
