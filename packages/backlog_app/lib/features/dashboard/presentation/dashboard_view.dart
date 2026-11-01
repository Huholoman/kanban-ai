import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/dashboard_controller.dart';
import 'dashboard_sections.dart';

/// What waits for me and what goes on in one project, in place of the
/// board: *Needs you* (questions to answer, work to approve, held items,
/// clean-up), *Running* (agents and the dispatcher's queue) and *Overview*
/// (milestones and urgent work). Two columns when there is room, one on
/// phones with *Needs you* first. A row opens its item with [onOpen].
class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.controller, required this.project, required this.onOpen, this.onMenu});

  final DashboardController controller;

  /// The project shown; null for the single backlog.
  final String? project;
  final OpenItem onOpen;

  /// Opens the navigation drawer; null when the navigation is always visible.
  final VoidCallback? onMenu;

  /// From this width *Running* and *Overview* sit beside *Needs you*.
  static const twoColumnWidth = 1000.0;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  StreamSubscription<String>? _notices;

  @override
  void initState() {
    super.initState();
    _notices = widget.controller.notices.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final digest = controller.digestOf(widget.project);
        final error = controller.errorOf(widget.project);
        Future<void> refresh() => controller.refreshProject(widget.project);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DashboardHeader(needsMe: digest?.needsMe ?? 0, onRefresh: refresh, onMenu: widget.onMenu),
            if (error != null)
              MaterialBanner(
                content: Text(digest == null ? '$error' : 'Showing older data: $error'),
                actions: [LinkButton(label: 'Retry', onPressed: refresh)],
              ),
            Expanded(
              child: digest == null
                  ? (error == null ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
                  : _sections(DashboardSections(digest: digest, controller: controller, onOpen: widget.onOpen)),
            ),
          ],
        );
      },
    );
  }

  Widget _sections(DashboardSections sections) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < DashboardView.twoColumnWidth) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [...sections.needsYou(), ...sections.running(), ...sections.overview()],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: sections.needsYou()),
          ),
          VerticalDivider(width: 1, color: BoardTokens.of(context).border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [...sections.running(), ...sections.overview()],
            ),
          ),
        ],
      );
    },
  );
}

/// Top bar of the dashboard, in place of the board's header: the menu on
/// narrow windows, the title with how much waits for you, and reload.
class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({required this.needsMe, required this.onRefresh, this.onMenu});

  final int needsMe;
  final Future<void> Function() onRefresh;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final menu = onMenu;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          if (menu != null) IconActionButton(tooltip: 'Menu', icon: Icons.menu, onPressed: menu),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              needsMe == 0 ? 'Dashboard' : 'Dashboard · $needsMe need you',
              key: const ValueKey('dashboard-title'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: tokens.text),
            ),
          ),
          IconActionButton(
            key: const ValueKey('dashboard-refresh'),
            tooltip: 'Reload',
            icon: Icons.refresh,
            onPressed: () => unawaited(onRefresh()),
          ),
        ],
      ),
    );
  }
}
