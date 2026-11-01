import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../dispatch/application/dispatch_controller.dart';
import '../../dispatch/presentation/dispatch_scope.dart';
import '../../item/presentation/item_page.dart';
import '../../projects/presentation/preview_banner.dart';
import '../application/dashboard_controller.dart';
import '../application/project_digest.dart';
import 'dashboard_sections.dart';

/// What waits for me and what goes on, across every project: *Needs you*
/// (questions to answer, work to approve, held items, clean-up), *Running*
/// (agents and the dispatcher's queue) and *Overview* (milestones and
/// urgent work). Two columns on wide windows, one on phones with *Needs
/// you* first.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.controller});

  final DashboardController controller;

  /// From this width *Running* and *Overview* sit beside *Needs you*.
  static const twoColumnWidth = 1000.0;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
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

  /// Opens [item] of [digest]'s project as a page, with that project's API.
  Future<void> _open(ProjectDigest digest, String item) async {
    final scope = AppScope.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AppScope(
          api: widget.controller.apiOf(digest),
          config: scope.config,
          appearance: scope.appearance,
          projects: scope.projects,
          dashboard: scope.dashboard,
          preview: scope.preview,
          child: _ProjectItemPage(reference: item),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final tokens = BoardTokens.of(context);
    final preview = AppScope.of(context).preview;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final digests = controller.shown;
        final labelled = controller.only == null && controller.digests.length > 1;
        final sections = DashboardSections(digests: digests, controller: controller, labelled: labelled, onOpen: _open);
        return Scaffold(
          backgroundColor: tokens.page,
          appBar: AppBar(
            title: Text(controller.needsMe == 0 ? 'Dashboard' : 'Dashboard · ${controller.needsMe} need you'),
            actions: [
              if (controller.projects.length > 1) _ProjectFilter(controller: controller),
              IconButton(
                key: const ValueKey('dashboard-refresh'),
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(controller.refresh()),
              ),
            ],
          ),
          body: controller.loading && digests.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final errors = [
                      if (preview != null) PreviewBanner(controller: preview),
                      for (final (name, error) in controller.errors)
                        MaterialBanner(
                          content: Text('$name: $error'),
                          actions: [TextButton(onPressed: controller.refresh, child: const Text('Retry'))],
                        ),
                    ];
                    if (constraints.maxWidth < DashboardPage.twoColumnWidth) {
                      return ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [...errors, ...sections.needsYou(), ...sections.running(), ...sections.overview()],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...errors,
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  children: sections.needsYou(),
                                ),
                              ),
                              VerticalDivider(width: 1, color: tokens.border),
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  children: [...sections.running(), ...sections.overview()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

/// Narrows the dashboard to one project.
class _ProjectFilter extends StatelessWidget {
  const _ProjectFilter({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('dashboard-project'),
    tooltip: 'Project',
    initialValue: controller.only ?? '',
    onSelected: (id) => controller.showOnly(id.isEmpty ? null : id),
    itemBuilder: (_) => [
      const PopupMenuItem(value: '', child: Text('All projects')),
      for (final project in controller.projects)
        PopupMenuItem(key: ValueKey('dashboard-project-${project.id}'), value: project.id, child: Text(project.name)),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(controller.projects.where((p) => p.id == controller.only).firstOrNull?.name ?? 'All projects'),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

/// An item of any project as a page, with its own dispatcher plan (agent
/// box, *Start agent*, actions).
class _ProjectItemPage extends StatefulWidget {
  const _ProjectItemPage({required this.reference});

  final String reference;

  @override
  State<_ProjectItemPage> createState() => _ProjectItemPageState();
}

class _ProjectItemPageState extends State<_ProjectItemPage> {
  DispatchController? _dispatch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_dispatch != null) return;
    final dispatch = _dispatch = DispatchController(AppScope.of(context).api);
    unawaited(dispatch.start());
  }

  @override
  void dispose() {
    _dispatch?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DispatchScope(
    controller: _dispatch!,
    child: ItemPage(reference: widget.reference),
  );
}
