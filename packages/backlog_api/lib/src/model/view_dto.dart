import 'item_dto.dart';
import 'json.dart';

enum ViewLayoutDto {
  list,
  kanban,
  table,
  graph;

  static ViewLayoutDto parse(String value) =>
      values.firstWhere((layout) => layout.name == value, orElse: () => ViewLayoutDto.list);
}

/// A saved view without its items, for the view picker.
final class ViewSummaryDto {
  const ViewSummaryDto({required this.id, required this.name, required this.layout, this.groupBy, this.section});

  factory ViewSummaryDto.fromJson(Json json) => ViewSummaryDto(
    id: json.string('id'),
    name: json.string('name'),
    layout: ViewLayoutDto.parse(json.string('layout')),
    groupBy: json.optionalString('group_by'),
    section: json.optionalString('section'),
  );

  final String id;
  final String name;
  final ViewLayoutDto layout;
  final String? groupBy;

  /// Heading in the view list; null for views outside any section.
  final String? section;

  Json toJson() => {'id': id, 'name': name, 'layout': layout.name, 'group_by': groupBy, 'section': section};
}

final class ViewGroupDto {
  const ViewGroupDto(this.key, this.items);

  factory ViewGroupDto.fromJson(Json json) =>
      ViewGroupDto(json.string('key'), json.objects('items').map(ItemDto.fromJson).toList());

  /// Value of the `group_by` field; empty for items without it.
  final String key;
  final List<ItemDto> items;

  Json toJson() => {
    'key': key,
    'items': [for (final item in items) item.toJson()],
  };
}

/// A view evaluated against the current backlog.
final class ViewResultDto {
  const ViewResultDto({
    required this.id,
    required this.name,
    required this.layout,
    this.groupBy,
    this.fields = const [],
    this.columns,
    this.hidden = 0,
    required this.groups,
  });

  factory ViewResultDto.fromJson(Json json) => ViewResultDto(
    id: json.string('id'),
    name: json.string('name'),
    layout: ViewLayoutDto.parse(json.string('layout')),
    groupBy: json.optionalString('group_by'),
    fields: json.strings('fields'),
    columns: json['columns'] == null ? null : json.strings('columns'),
    hidden: json.integer('hidden'),
    groups: json.objects('groups').map(ViewGroupDto.fromJson).toList(),
  );

  final String id;
  final String name;
  final ViewLayoutDto layout;
  final String? groupBy;
  final List<String> fields;

  /// Groups the view is configured to show, in order; null for the default
  /// (every value of the grouping field).
  final List<String>? columns;

  /// Items that matched the filter but fall outside the shown columns.
  final int hidden;
  final List<ViewGroupDto> groups;

  List<ItemDto> get items => [for (final group in groups) ...group.items];

  ViewSummaryDto get summary => ViewSummaryDto(id: id, name: name, layout: layout, groupBy: groupBy);

  Json toJson() => {
    'id': id,
    'name': name,
    'layout': layout.name,
    'group_by': groupBy,
    'fields': fields,
    'columns': columns,
    'hidden': hidden,
    'groups': [for (final group in groups) group.toJson()],
  };
}
