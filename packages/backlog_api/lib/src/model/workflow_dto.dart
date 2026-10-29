import 'json.dart';

enum StatusCategoryDto { open, active, done }

final class StatusDto {
  const StatusDto({required this.id, required this.category, this.pickable = false});

  factory StatusDto.fromJson(Json json) => StatusDto(
    id: json.string('id'),
    category: StatusCategoryDto.values.byName(json.string('category')),
    pickable: json.boolean('pickable'),
  );

  final String id;
  final StatusCategoryDto category;
  final bool pickable;

  Json toJson() => {'id': id, 'category': category.name, 'pickable': pickable};
}

final class MilestoneDto {
  const MilestoneDto({required this.id, this.title, this.due});

  factory MilestoneDto.fromJson(Json json) =>
      MilestoneDto(id: json.string('id'), title: json.optionalString('title'), due: json.optionalString('due'));

  final String id;
  final String? title;
  final String? due;

  Json toJson() => {'id': id, 'title': title, 'due': due};
}

/// The allowed values of a backlog — what the UI offers in pickers.
final class WorkflowDto {
  const WorkflowDto({
    required this.statuses,
    required this.priorities,
    required this.types,
    this.milestones = const [],
    required this.defaultStatus,
    required this.defaultPriority,
    required this.defaultType,
  });

  factory WorkflowDto.fromJson(Json json) {
    final defaults = json.object('defaults');
    return WorkflowDto(
      statuses: json.objects('statuses').map(StatusDto.fromJson).toList(),
      priorities: json.strings('priorities'),
      types: json.strings('types'),
      milestones: json.objects('milestones').map(MilestoneDto.fromJson).toList(),
      defaultStatus: defaults.string('status'),
      defaultPriority: defaults.string('priority'),
      defaultType: defaults.string('type'),
    );
  }

  final List<StatusDto> statuses;
  final List<String> priorities;
  final List<String> types;
  final List<MilestoneDto> milestones;
  final String defaultStatus;
  final String defaultPriority;
  final String defaultType;

  StatusCategoryDto? categoryOf(String status) {
    for (final definition in statuses) {
      if (definition.id == status) return definition.category;
    }
    return null;
  }

  Json toJson() => {
    'statuses': [for (final status in statuses) status.toJson()],
    'priorities': priorities,
    'types': types,
    'milestones': [for (final milestone in milestones) milestone.toJson()],
    'defaults': {'status': defaultStatus, 'priority': defaultPriority, 'type': defaultType},
  };
}
