import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/projects_controller.dart';

/// The open project's name at the top of the navigation. With more than one
/// project it opens a menu of all of them: the open one ticked, the ones
/// the server cannot open greyed out with the reason. With a single project
/// (or a server without projects) it is just the name.
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

/// The menu's sections: a heading (null for none) and its projects. Today
/// one unnamed section with every project; pinned projects can get their own
/// section on top with the rest under "All" (folded, with a search box when
/// long, like the sections of the filters popover).
List<(String?, List<ProjectDto>)> _sections(ProjectsController controller) => [(null, controller.projects)];

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
      trailingIcon: open ? Icon(Icons.check, size: 16, color: tokens.accent) : null,
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
