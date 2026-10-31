import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/agent_log_controller.dart';
import 'agent_log_view.dart';
import 'dispatch_scope.dart';

/// `14:05 (12 min)`: when [time] was, and how long ago.
String sinceText(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final minutes = (now ?? DateTime.now()).difference(time).inMinutes;
  String two(int value) => value.toString().padLeft(2, '0');
  final ago = minutes < 1
      ? 'just now'
      : minutes < 60
      ? '$minutes min'
      : '${minutes ~/ 60} h ${minutes % 60} min';
  return '${two(local.hour)}:${two(local.minute)} ($ago)';
}

/// The dispatcher's view of one item in its detail: the agent working on it
/// (worktree, since when, branch, its live log, *Stop*), why the dispatcher
/// holds it back, or the log of its last run. Empty when none applies.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.item});

  final ItemDto item;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  AgentLogController? _log;

  /// Shown or hidden by the reader; by default shown while an agent runs.
  bool? _showLogChoice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_log == null && DispatchScope.maybeOf(context)?.configured == true) {
      _log = AgentLogController(AppScope.of(context).api, widget.item.id)
        ..addListener(_logChanged)
        ..start();
    }
  }

  void _logChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _log?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dispatch = DispatchScope.maybeOf(context);
    if (dispatch == null || !dispatch.configured) return const SizedBox.shrink();
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final id = widget.item.id;
    final run = dispatch.runFor(id);
    final held = dispatch.plan.heldReason(id);
    final log = _log;
    final hasLog = log?.hasLog ?? false;
    if (run == null && held == null && !hasLog) return const SizedBox.shrink();
    final showLog = hasLog && (_showLogChoice ?? (run != null || (log?.running ?? false)));
    return Container(
      key: const ValueKey('agent-panel'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.well,
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(BoardTokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                run != null ? Icons.smart_toy : Icons.pause_circle_outline,
                size: 18,
                color: run != null ? tokens.success : tokens.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: run != null
                    ? Text(
                        'Agent ${run.agent} in ${run.worktree} since ${sinceText(run.startedAt)}'
                        '${run.branch == null ? '' : ' · ${run.branch}'}',
                        key: const ValueKey('agent-running'),
                        style: small?.copyWith(color: tokens.text),
                      )
                    : Text(
                        held == null ? 'Agent · last run' : 'Held: $held',
                        key: const ValueKey('agent-held'),
                        style: small?.copyWith(color: tokens.text),
                      ),
              ),
              if (hasLog)
                LinkButton(
                  key: const ValueKey('agent-log-toggle'),
                  label: showLog ? 'Hide log' : 'Log',
                  onPressed: () => setState(() => _showLogChoice = !showLog),
                ),
              if (run != null)
                SecondaryButton(
                  key: const ValueKey('stop-agent'),
                  label: 'Stop',
                  icon: Icons.stop,
                  onPressed: dispatch.pending.contains(id) ? null : () => unawaited(_confirmStop(dispatch.stopAgent)),
                ),
            ],
          ),
          if (showLog && log != null) ...[const SizedBox(height: 8), AgentLogView(controller: log)],
        ],
      ),
    );
  }

  Future<void> _confirmStop(Future<void> Function(String item) stop) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop the agent of ${widget.item.id}?'),
        content: const Text(
          'Its process is terminated; the item goes back to the queue and is held. '
          'Uncommitted changes stay in the worktree.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Stop')),
        ],
      ),
    );
    if (confirmed == true) await stop(widget.item.id);
  }
}
