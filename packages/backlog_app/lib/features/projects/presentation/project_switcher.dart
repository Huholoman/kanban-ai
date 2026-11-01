import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/projects_controller.dart';

/// The open project's name at the top of the navigation. With more than one
/// project it opens a menu: the pinned projects (`pinned: true` in the
/// registry), or all of them when none is pinned — the open one ticked, the
/// others with how much waits for a person in them, the ones the server
/// cannot open greyed out with the reason — and *All
/// projects…*, a dialog that searches every project and pins or unpins them.
/// With a single project (or a server without projects) it is just the name.
class ProjectSwitcher extends StatelessWidget {
  const ProjectSwitcher({super.key});

  /// Name shown for a server without projects.
  static const appName = 'kanban-ai';

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final controller = AppScope.of(context).projects;
    final name = controller?.current?.name ?? appName;
    final label = Text(
      name,
      key: const ValueKey('project-name'),
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tokens.text),
    );
    if (controller == null || controller.projects.length < 2) {
      return SizedBox(
        height: 36,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(alignment: Alignment.centerLeft, child: label),
        ),
      );
    }
    final sections = _sections(controller);
    // As wide as the navigation, just below the name, and set off from the
    // panel by a border and a shadow: both have the surface colour.
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(tokens.surface),
          side: WidgetStatePropertyAll(BorderSide(color: tokens.borderStrong)),
          elevation: const WidgetStatePropertyAll(8),
          shadowColor: const WidgetStatePropertyAll(Colors.black54),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(BoardTokens.radius)),
          ),
          padding: const WidgetStatePropertyAll(EdgeInsets.only(bottom: 4)),
        ),
        menuChildren: [
          SizedBox(
            width: constraints.maxWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sections.first.$1 == null) const SectionLabel('Projects', key: ValueKey('project-section-header')),
                for (final (title, projects) in sections) ...[
                  if (title != null) SectionLabel(title, key: ValueKey('project-section-$title')),
                  for (final project in projects) _ProjectEntry(controller: controller, project: project),
                ],
                const Divider(height: 9),
                MenuItemButton(
                  key: const ValueKey('project-all'),
                  leadingIcon: Icon(Icons.search, size: 18, color: tokens.muted),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AllProjectsDialog(controller: controller),
                  ),
                  child: Text('All projects (${controller.projects.length})…', style: TextStyle(color: tokens.text)),
                ),
              ],
            ),
          ),
        ],
        builder: (context, menu, _) => Tooltip(
          message: 'Switch project',
          child: InkWell(
            key: const ValueKey('project-switcher'),
            borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
            onTap: () => menu.isOpen ? menu.close() : menu.open(),
            child: SizedBox(
              height: 36,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: Row(
                  children: [
                    Flexible(child: label),
                    const SizedBox(width: 4),
                    Icon(Icons.unfold_more, size: 18, color: tokens.muted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The menu's sections: a heading (null for none) and its projects. Without
/// pinned projects one unnamed section with every project; else *Pinned*,
/// and the open project under *Open* when it is not pinned. The rest is in
/// [AllProjectsDialog].
List<(String?, List<ProjectDto>)> _sections(ProjectsController controller) {
  final pinned = controller.pinned;
  if (pinned.isEmpty) return [(null, controller.projects)];
  final current = controller.current;
  return [
    ('Pinned', pinned),
    if (current != null && !current.pinned) ('Open', [current]),
  ];
}

/// Every project, with a search box when there are many: a click opens one,
/// the pin keeps it in the switcher's menu (for everybody: the server writes
/// `pinned` into its registry).
class AllProjectsDialog extends StatefulWidget {
  const AllProjectsDialog({super.key, required this.controller});

  /// From this many projects the dialog has a search box.
  static const searchFrom = 8;

  final ProjectsController controller;

  @override
  State<AllProjectsDialog> createState() => _AllProjectsDialogState();
}

class _AllProjectsDialogState extends State<AllProjectsDialog> {
  final _query = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _pin(ProjectDto project) async {
    try {
      await widget.controller.setPinned(project.id, !project.pinned);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final controller = widget.controller;
    return AlertDialog(
      title: const Text('All projects'),
      contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      content: SizedBox(
        width: 480,
        height: 420,
        child: ListenableBuilder(
          listenable: Listenable.merge([controller, _query]),
          builder: (context, _) {
            final text = _query.text.trim().toLowerCase();
            final shown = [
              for (final project in controller.projects)
                if (text.isEmpty ||
                    project.name.toLowerCase().contains(text) ||
                    project.id.toLowerCase().contains(text))
                  project,
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.projects.length >= AllProjectsDialog.searchFrom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: TextField(
                      key: const ValueKey('project-search'),
                      controller: _query,
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Search projects',
                      ),
                    ),
                  ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(error, style: TextStyle(color: tokens.danger, fontSize: 12)),
                  ),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text('No project matches.', style: TextStyle(color: tokens.muted)),
                        )
                      : ListView(children: [for (final project in shown) _projectRow(context, project)]),
                ),
              ],
            );
          },
        ),
      ),
      actions: [LinkButton(label: 'Close', onPressed: () => Navigator.of(context).pop())],
    );
  }

  Widget _projectRow(BuildContext context, ProjectDto project) {
    final tokens = BoardTokens.of(context);
    final open = project.id == widget.controller.current?.id;
    final error = project.error;
    return ListTile(
      key: ValueKey('all-project-${project.id}'),
      dense: true,
      leading: Icon(
        error == null ? Icons.folder_outlined : Icons.error_outline,
        size: 18,
        color: error == null ? (open ? tokens.accent : tokens.muted) : tokens.danger,
      ),
      title: Text(
        project.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: error != null ? tokens.faint : (open ? tokens.accent : tokens.text),
          fontWeight: open ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        error ?? project.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: error == null ? tokens.muted : tokens.danger),
      ),
      trailing: IconButton(
        key: ValueKey('pin-project-${project.id}'),
        tooltip: project.pinned ? 'Unpin (keep it out of the menu)' : 'Pin to the menu',
        iconSize: 18,
        color: project.pinned ? tokens.accent : tokens.muted,
        icon: Icon(project.pinned ? Icons.push_pin : Icons.push_pin_outlined),
        onPressed: () => _pin(project),
      ),
      onTap: open || error != null
          ? null
          : () {
              Navigator.of(context).pop();
              widget.controller.select(project.id);
            },
    );
  }
}

class _ProjectEntry extends StatelessWidget {
  const _ProjectEntry({required this.controller, required this.project});

  final ProjectsController controller;
  final ProjectDto project;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final open = project.id == controller.current?.id;
    final error = project.error;
    return MenuItemButton(
      key: ValueKey('project-${project.id}'),
      leadingIcon: Icon(
        error == null ? Icons.folder_outlined : Icons.error_outline,
        size: 18,
        color: error == null ? (open ? tokens.accent : tokens.muted) : tokens.danger,
      ),
      trailingIcon: switch ((open, AppScope.of(context).dashboard)) {
        (true, _) => Icon(Icons.check, size: 16, color: tokens.accent),
        (false, final dashboard?) => ListenableBuilder(
          listenable: dashboard,
          builder: (context, _) => switch (dashboard.needsMeIn(project.id)) {
            0 => const SizedBox.shrink(),
            final count => Tooltip(
              message: '$count waiting for you in ${project.name}',
              child: CountBadge(count, key: ValueKey('project-needs-${project.id}')),
            ),
          },
        ),
        _ => null,
      },
      onPressed: open || error != null ? null : () => controller.select(project.id),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              project.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: error != null ? tokens.faint : (open ? tokens.accent : tokens.text),
                fontWeight: open ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (error != null)
              Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: tokens.danger),
              ),
          ],
        ),
      ),
    );
  }
}
