import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../../shared/tokens.dart';

/// The lint summary ("Lint: 2 warnings"); a click lists the issues.
class LintLink extends StatelessWidget {
  const LintLink({super.key, required this.issues, required this.onOpenItem});

  final List<LintIssueDto> issues;

  /// Opens the item of an issue.
  final void Function(String id) onOpenItem;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final errors = issues.where((issue) => issue.isError).length;
    final warnings = issues.length - errors;
    final parts = [
      if (errors > 0) '$errors ${errors == 1 ? 'error' : 'errors'}',
      if (warnings > 0) '$warnings ${warnings == 1 ? 'warning' : 'warnings'}',
    ];
    final color = errors > 0 ? tokens.danger : (warnings > 0 ? tokens.warning : tokens.muted);
    return InkWell(
      key: const ValueKey('lint'),
      onTap: issues.isEmpty ? null : () => _show(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(issues.isEmpty ? Icons.verified_outlined : Icons.rule, size: 16, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                issues.isEmpty ? 'Lint: all good' : 'Lint: ${parts.join(', ')}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final tokens = BoardTokens.of(dialogContext);
      return AlertDialog(
        title: const Text('Lint'),
        content: SizedBox(
          width: 640,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final issue in issues)
                ListTile(
                  dense: true,
                  leading: Icon(
                    issue.isError ? Icons.error_outline : Icons.warning_amber,
                    color: issue.isError ? tokens.danger : tokens.warning,
                  ),
                  title: Text(issue.message),
                  subtitle: Text([issue.code, ?issue.item, ?issue.location].join(' · ')),
                  onTap: issue.item == null
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                          onOpenItem(issue.item!);
                        },
                ),
            ],
          ),
        ),
      );
    },
  );
}
