import 'package:path/path.dart' as p;

import '../../planning/application/planning_service.dart';
import '../../shared/errors.dart';
import '../domain/view.dart';

final class ViewService {
  ViewService({required ViewRepository views, required PlanningService planning})
    : _views = views,
      _planning = planning;

  final ViewRepository _views;
  final PlanningService _planning;

  Future<List<ViewDefinition>> all() async => (await _views.load()).views;

  /// Runs view [id]; with [groupBy] grouped by that field for this run only
  /// (empty string: ungrouped), the saved definition stays as it is.
  Future<ViewResult> run(String id, {String? groupBy}) async {
    final catalog = await _views.load();
    for (final view in catalog.views) {
      if (view.id != id) continue;
      return evaluate(groupBy == null ? view : view.regroupedBy(groupBy.isEmpty ? null : groupBy));
    }
    final broken = catalog.problems.where((problem) => p.basenameWithoutExtension(problem.$1) == id);
    if (broken.isNotEmpty) throw ConfigurationException('${broken.first.$1}: ${broken.first.$2}');
    throw NotFoundException('No view "$id" (available: ${catalog.views.map((v) => v.id).join(', ')}).');
  }

  Future<ViewDefinition> setSection(String id, String? section) async {
    await _views.setSection(id, section);
    return _reloaded(id);
  }

  Future<ViewDefinition> setPinned(String id, bool pinned) async {
    await _views.setPinned(id, pinned);
    return _reloaded(id);
  }

  Future<ViewDefinition> setColumns(String id, List<String>? columns) async {
    await _views.setColumns(id, columns);
    return _reloaded(id);
  }

  /// Saves a new view named [name]: a copy of [base] (layout, grouping,
  /// columns, sorting) whose filter additionally requires every condition in
  /// [conditions] (filter expressions in the YAML grammar).
  Future<ViewDefinition> saveAs({
    required String name,
    String? section,
    bool pinned = false,
    String? base,
    List<Object?> conditions = const [],
  }) async {
    if (name.trim().isEmpty) throw const InvalidInputException('A view needs a name.');
    final template = base == null ? <String, Object?>{} : await _views.raw(base);
    final baseFilter = template['filter'];
    final parts = [?baseFilter, ...conditions];
    final definition = <String, Object?>{
      'name': name.trim(),
      if (section != null && section.trim().isNotEmpty) 'section': section.trim(),
      if (pinned) 'pinned': true,
      'layout': template['layout'] ?? 'list',
      if (parts.isNotEmpty) 'filter': parts.length == 1 ? parts.single : {'and': parts},
      for (final key in ['group_by', 'columns', 'sort', 'fields'])
        if (template[key] != null) key: template[key],
    };
    final String id;
    try {
      id = await _views.create(name, definition); // validates before writing
    } on ConfigurationException catch (e) {
      throw InvalidInputException('Not a valid view: ${e.message}');
    }
    return _reloaded(id);
  }

  Future<ViewDefinition> _reloaded(String id) async {
    final updated = (await _views.load()).views.where((view) => view.id == id).firstOrNull;
    return updated ?? (throw NotFoundException('No view "$id".'));
  }

  /// Runs a definition that is not saved, e.g. built from CLI options.
  Future<ViewResult> evaluate(ViewDefinition view) async => ViewEngine.evaluate(view, await _planning.snapshot());
}
