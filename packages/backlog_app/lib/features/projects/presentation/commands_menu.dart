import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/commands_controller.dart';

/// The server's global commands (`commands` in `server.yaml`) as a menu at
/// the top right: choosing one starts it and shows its output and result
/// ([CommandRunDialog]); the last run can be opened again. Nothing while
/// the server has no commands.
class CommandsMenu extends StatelessWidget {
  const CommandsMenu({super.key, required this.controller});

  final CommandsController controller;

  Future<void> _run(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await controller.runCommand(name)) {
      if (context.mounted) await CommandRunDialog.show(context, controller);
    } else {
      messenger?.showSnackBar(SnackBar(content: Text('$name did not start: ${controller.error}')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.commands.isEmpty) return const SizedBox.shrink();
      final tokens = BoardTokens.of(context);
      final run = controller.run;
      return MenuAnchor(
        onOpen: () => unawaited(controller.refresh()),
        menuChildren: [
          for (final command in controller.commands)
            MenuItemButton(
              key: ValueKey('command-${command.name}'),
              leadingIcon: Icon(command.restarts ? Icons.restart_alt : Icons.play_arrow_outlined, size: 18),
              onPressed: controller.running ? null : () => unawaited(_run(context, command.name)),
              child: Text(command.restarts ? '${command.name} (restarts the server)' : command.name),
            ),
          if (run != null) ...[
            const Divider(height: 1),
            MenuItemButton(
              key: const ValueKey('command-last-run'),
              leadingIcon: _RunIcon(run: run, size: 18),
              onPressed: () => unawaited(CommandRunDialog.show(context, controller)),
              child: Text(run.running ? '${run.name}: running…' : 'Last: ${run.name} – ${_outcome(run)}'),
            ),
          ],
        ],
        builder: (context, menu, _) => IconButton(
          key: const ValueKey('commands'),
          tooltip: controller.running ? 'Commands (${run!.name} running)' : 'Commands',
          iconSize: 20,
          icon: controller.running
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.terminal, color: tokens.muted),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      );
    },
  );
}

/// The output and result of the command running or run last, live while it
/// runs.
class CommandRunDialog extends StatelessWidget {
  const CommandRunDialog({super.key, required this.controller});

  final CommandsController controller;

  static Future<void> show(BuildContext context, CommandsController controller) => showDialog<void>(
    context: context,
    builder: (_) => CommandRunDialog(controller: controller),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final tokens = BoardTokens.of(context);
      final run = controller.run;
      final muted = TextStyle(fontSize: 13, color: tokens.muted);
      return AlertDialog(
        key: const ValueKey('command-run'),
        title: Row(
          children: [
            if (run != null) ...[_RunIcon(run: run, size: 22), const SizedBox(width: 8)],
            Expanded(child: Text(run?.name ?? 'Commands')),
          ],
        ),
        content: SizedBox(
          width: 720,
          child: run == null
              ? const Text('No command has run yet.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        Text(run.running ? 'Running' : _outcome(run), key: const ValueKey('command-outcome')),
                        TimeText(run.started, prefix: 'started ', style: muted),
                      ],
                    ),
                    if (run.restart case final program? when run.succeeded)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'The server restarts as $program; reload the page in a moment.',
                          style: TextStyle(fontSize: 13, color: tokens.warning),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 80, maxHeight: 420),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: tokens.well,
                          border: Border.all(color: tokens.border),
                          borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
                        ),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: SelectableText(
                            run.output.isEmpty ? '(no output yet)' : run.output,
                            key: const ValueKey('command-output'),
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      );
    },
  );
}

String _outcome(CommandRunDto run) => switch (run) {
  _ when run.succeeded => 'succeeded',
  CommandRunDto(:final error?) => 'failed: $error',
  _ => 'failed (exit code ${run.exitCode})',
};

class _RunIcon extends StatelessWidget {
  const _RunIcon({required this.run, required this.size});

  final CommandRunDto run;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    if (run.running) {
      return SizedBox(width: size - 4, height: size - 4, child: const CircularProgressIndicator(strokeWidth: 2));
    }
    return run.succeeded
        ? Icon(Icons.check_circle_outline, size: size, color: tokens.success)
        : Icon(Icons.error_outline, size: size, color: tokens.danger);
  }
}
