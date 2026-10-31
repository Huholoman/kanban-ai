import 'action_dto.dart';
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

/// Colours of one brightness as `#rrggbb`; all optional.
final class PaletteDto {
  const PaletteDto({this.seed, this.primary, this.secondary, this.background});

  factory PaletteDto.fromJson(Json? json) => json == null
      ? const PaletteDto()
      : PaletteDto(
          seed: json.optionalString('seed'),
          primary: json.optionalString('primary'),
          secondary: json.optionalString('secondary'),
          background: json.optionalString('background'),
        );

  final String? seed;
  final String? primary;
  final String? secondary;
  final String? background;

  Json toJson() => {'seed': seed, 'primary': primary, 'secondary': secondary, 'background': background};
}

/// How the board should look (`appearance` in backlog.yaml).
final class AppearanceDto {
  const AppearanceDto({
    this.mode = 'system',
    this.light = const PaletteDto(),
    this.dark = const PaletteDto(),
    this.statuses = const {},
    this.priorities = const {},
    this.types = const {},
    this.labels = const {},
  });

  factory AppearanceDto.fromJson(Json? json) {
    if (json == null) return const AppearanceDto();
    Map<String, String> colors(String key) => {
      for (final MapEntry(:key, :value) in (json.optionalObject(key) ?? const {}).entries)
        if (value is String) key: value,
    };
    return AppearanceDto(
      mode: json.optionalString('mode') ?? 'system',
      light: PaletteDto.fromJson(json.optionalObject('light')),
      dark: PaletteDto.fromJson(json.optionalObject('dark')),
      statuses: colors('statuses'),
      priorities: colors('priorities'),
      types: colors('types'),
      labels: colors('labels'),
    );
  }

  /// `system`, `light` or `dark`.
  final String mode;
  final PaletteDto light;
  final PaletteDto dark;
  final Map<String, String> statuses;
  final Map<String, String> priorities;
  final Map<String, String> types;
  final Map<String, String> labels;

  Json toJson() => {
    'mode': mode,
    'light': light.toJson(),
    'dark': dark.toJson(),
    'statuses': statuses,
    'priorities': priorities,
    'types': types,
    'labels': labels,
  };
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
    this.appearance = const AppearanceDto(),
    this.actions = const [],
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
      appearance: AppearanceDto.fromJson(json.optionalObject('appearance')),
      actions: json.objects('actions').map(ActionDto.fromJson).toList(),
    );
  }

  final List<StatusDto> statuses;
  final List<String> priorities;
  final List<String> types;
  final List<MilestoneDto> milestones;
  final String defaultStatus;
  final String defaultPriority;
  final String defaultType;
  final AppearanceDto appearance;

  /// `dispatcher.actions` (empty without a dispatcher).
  final List<ActionDto> actions;

  /// The actions items in [status] show as buttons.
  List<ActionDto> actionsIn(String status) => [
    for (final action in actions)
      if (action.offeredIn(status)) action,
  ];

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
    'appearance': appearance.toJson(),
    'actions': [for (final action in actions) action.toJson()],
  };
}
