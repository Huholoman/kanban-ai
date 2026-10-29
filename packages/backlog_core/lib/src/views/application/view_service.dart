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

  Future<ViewResult> run(String id) async {
    final catalog = await _views.load();
    for (final view in catalog.views) {
      if (view.id == id) return evaluate(view);
    }
    final broken = catalog.problems.where((problem) => p.basenameWithoutExtension(problem.$1) == id);
    if (broken.isNotEmpty) throw ConfigurationException('${broken.first.$1}: ${broken.first.$2}');
    throw NotFoundException('No view "$id" (available: ${catalog.views.map((v) => v.id).join(', ')}).');
  }

  Future<ViewDefinition> setSection(String id, String? section) async {
    await _views.setSection(id, section);
    final updated = (await _views.load()).views.where((view) => view.id == id).firstOrNull;
    return updated ?? (throw NotFoundException('No view "$id".'));
  }

  /// Runs a definition that is not saved, e.g. built from CLI options.
  Future<ViewResult> evaluate(ViewDefinition view) async => ViewEngine.evaluate(view, await _planning.snapshot());
}
