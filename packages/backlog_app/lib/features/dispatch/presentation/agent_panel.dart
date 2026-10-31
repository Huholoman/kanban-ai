import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
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
/// (worktree, since when, branch, its log, *Stop*), or why the dispatcher
/// holds it back. Empty when neither applies.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.item});

  final ItemDto item;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  bool _showLog = false;
  AgentLogDto? _log;
  Object? _logError;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadLog() async {
    try {
      final log = await AppScope.of(context).api.agentLog(widget.item.id, lines: 60);
      if (mounted) {
        setState(() {
          _log = log;
          _logError = null;
        });
      }
    } on BacklogApiException catch (error) {
      if (mounted) setState(() => _logError = error.message);
    }
  }

  void _toggleLog() {
    setState(() => _showLog = !_showLog);
    _poll?.cancel();
    if (!_showLog) return;
    unawaited(_loadLog());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_log?.running ?? true) unawaited(_loadLog());
    });
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
    if (run == null && held == null && !_showLog) return const SizedBox.shrink();
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
                        held == null ? 'No agent runs.' : 'Held: $held',
                        key: const ValueKey('agent-held'),
                        style: small?.copyWith(color: tokens.text),
                      ),
              ),
              LinkButton(label: _showLog ? 'Hide log' : 'Log', onPressed: _toggleLog),
              if (run != null)
                SecondaryButton(
                  key: const ValueKey('stop-agent'),
                  label: 'Stop',
                  icon: Icons.stop,
                  onPressed: dispatch.pending.contains(id) ? null : () => unawaited(_confirmStop(dispatch.stopAgent)),
                ),
            ],
          ),
          if (_showLog) ...[
            const SizedBox(height: 8),
            if (_logError != null) Text('$_logError', style: small),
            if (_log case final log?) ...[
              Text(
                log.running
                    ? log.path
                    : '${log.path} · ${log.last?.reason ?? 'ended'}; ${log.last?.outcome ?? ''}'
                          '${log.last?.sessionId == null ? '' : ' · claude --resume ${log.last!.sessionId}'}',
                style: small?.copyWith(color: tokens.muted),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(4)),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    log.lines.join('\n'),
                    key: const ValueKey('agent-log'),
                    style: small?.copyWith(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ],
          ],
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
