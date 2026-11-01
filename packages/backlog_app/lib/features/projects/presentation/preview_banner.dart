import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/preview_controller.dart';

/// "Preview of KA-fsfc running (branch @ commit, since …) · Back to main"
/// while the server runs a local preview; nothing otherwise.
class PreviewBanner extends StatelessWidget {
  const PreviewBanner({super.key, required this.controller});

  final PreviewController controller;

  Future<void> _backToMain(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final program = await controller.backToMain();
    final message = program != null
        ? 'The server restarts as $program; reload the page in a moment for its board.'
        : 'Back to main failed: ${controller.error}';
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final preview = controller.current;
      if (preview == null) return const SizedBox.shrink();
      final tokens = BoardTokens.of(context);
      final muted = TextStyle(fontSize: 13, color: tokens.muted);
      return Container(
        key: const ValueKey('preview-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: tokens.warning.withValues(alpha: 0.12),
          border: Border(bottom: BorderSide(color: tokens.warning.withValues(alpha: 0.5))),
        ),
        child: Row(
          children: [
            Icon(Icons.preview_outlined, size: 18, color: tokens.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Tooltip(
                    message: preview.title,
                    child: Text(
                      'Preview of ${preview.item} running',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tokens.text),
                    ),
                  ),
                  Tooltip(
                    message: '${preview.commit}, rebased onto ${preview.base}; server ${preview.server}',
                    child: Text('${preview.branch} @ ${preview.shortCommit}', style: muted),
                  ),
                  TimeText(preview.since, prefix: 'since ', style: muted),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Restart the server as ${preview.mainServer}',
              child: SecondaryButton(
                key: const ValueKey('preview-back-to-main'),
                label: controller.restarting ? 'Restarting…' : 'Back to main',
                icon: Icons.undo,
                onPressed: controller.restarting ? null : () => unawaited(_backToMain(context)),
              ),
            ),
          ],
        ),
      );
    },
  );
}
