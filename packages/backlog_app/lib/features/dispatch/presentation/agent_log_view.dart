import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/agent_log_controller.dart';

/// The live log of an agent: its readable lines in a scrolling box that
/// stays at the end while new lines come, pauses when the reader scrolls up
/// (*Jump to end* resumes), and for an ended run how it ended.
class AgentLogView extends StatefulWidget {
  const AgentLogView({super.key, required this.controller, this.height = 280});

  final AgentLogController controller;
  final double height;

  @override
  State<AgentLogView> createState() => _AgentLogViewState();
}

class _AgentLogViewState extends State<AgentLogView> {
  final _scroll = ScrollController();

  /// Keep showing the newest lines; off while the reader looks further up.
  bool _follow = true;

  /// Scrolling caused by [_toEnd], not by the reader.
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  @override
  void didUpdateWidget(AgentLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_follow) WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  /// Jumps to the end; again in the next frames while the lazily built list
  /// finds out that it is longer (at most [retries] times).
  void _toEnd([int retries = 5]) {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent) return;
    _jumping = true;
    try {
      _scroll.jumpTo(position.maxScrollExtent);
    } finally {
      _jumping = false;
    }
    if (retries > 0) WidgetsBinding.instance.addPostFrameCallback((_) => _follow ? _toEnd(retries - 1) : null);
  }

  bool _onScroll(ScrollNotification notification) {
    // Only the reader's own scrolling (drag, wheel, keys) pauses or resumes.
    if (_jumping || (notification is! ScrollUpdateNotification && notification is! ScrollEndNotification)) {
      return false;
    }
    final metrics = notification.metrics;
    final atEnd = metrics.pixels >= metrics.maxScrollExtent - 16;
    if (atEnd != _follow) setState(() => _follow = atEnd);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.controller;
    final tokens = BoardTokens.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final mono = small?.copyWith(fontFamily: 'monospace', fontSize: 11, color: tokens.text, height: 1.35);
    final last = log.last;
    final status = log.running
        ? 'Live · ${log.path}'
        : [
            'Last run',
            ?last?.reason,
            ?last?.outcome,
            if (last?.sessionId case final session?) 'claude --resume $session',
          ].join(' · ');
    return Column(
      key: const ValueKey('agent-log-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                status,
                key: const ValueKey('agent-log-status'),
                style: small?.copyWith(color: tokens.muted),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            if (!_follow)
              LinkButton(
                key: const ValueKey('agent-log-follow'),
                label: 'Paused · jump to end',
                icon: Icons.arrow_downward,
                compact: true,
                onPressed: () {
                  setState(() => _follow = true);
                  _toEnd();
                },
              ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: tokens.surface,
            border: Border.all(color: tokens.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: log.lines.isEmpty
              ? Text(log.loaded ? 'The log is empty.' : 'Loading…', style: small?.copyWith(color: tokens.muted))
              : NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: SelectionArea(
                    child: ListView.builder(
                      key: const ValueKey('agent-log'),
                      controller: _scroll,
                      itemCount: log.lines.length + (log.dropped > 0 ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (log.dropped > 0) {
                          if (index == 0) {
                            return Text('… ${log.dropped} earlier lines', style: mono?.copyWith(color: tokens.faint));
                          }
                          index--;
                        }
                        final line = log.lines[index];
                        return Text(line.isEmpty ? ' ' : line, style: _styleOf(line, mono, tokens));
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// Tool calls, failures, results and the launcher's lines stand out
  /// from the agent's text.
  static TextStyle? _styleOf(String line, TextStyle? base, BoardTokens tokens) {
    if (line.startsWith('▸ ')) return base?.copyWith(color: tokens.accent);
    if (line.startsWith('  ✗') || line.startsWith('! ')) return base?.copyWith(color: tokens.danger);
    if (line.startsWith('■ ') || line.startsWith('● ')) return base?.copyWith(color: tokens.success);
    if (line.startsWith('# ')) return base?.copyWith(color: tokens.muted);
    return base;
  }
}
