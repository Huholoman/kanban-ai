import 'package:backlog_api/backlog_api.dart';

/// Item fields the board can be narrowed by. Status is left out on purpose:
/// views show it as columns or groups.
enum FilterFacet {
  label('Labels'),
  epic('Epic'),
  type('Type'),
  priority('Priority'),
  milestone('Milestone'),
  person('People');

  const FilterFacet(this.title);

  final String title;

  /// Values of this facet on [item]; people are the assignee and whoever
  /// holds the claim, epics are the epics above the item (or the item itself),
  /// looked up in [index].
  Iterable<String> valuesOf(ItemDto item, [Map<String, ItemDto> index = const {}]) => switch (this) {
    label => item.labels,
    epic => _epicsAbove(item, index),
    type => [item.type],
    priority => [item.priority],
    milestone => [?item.milestone],
    person => {?item.assignee, ?item.claim?.agent},
  };

  /// How a value is shown in the menu: epics by title, labels with `#`.
  String describe(String value, Map<String, ItemDto> index) => switch (this) {
    epic => index[value]?.title ?? value,
    label => '#$value',
    _ => value,
  };

  static List<String> _epicsAbove(ItemDto item, Map<String, ItemDto> index) {
    final epics = <String>[];
    final seen = <String>{};
    for (ItemDto? current = item; current != null && seen.add(current.id); current = index[current.parent]) {
      if (current.type == 'epic') epics.add(current.id);
    }
    return epics;
  }
}

/// Planning state an item can be required to have.
enum ItemFlag {
  ready(
    'Ready',
    'Can be picked up now: in a pickable status (todo), all dependencies done, '
        'no open children, nobody holds it.',
  ),
  blocked('Blocked', 'Waits for a dependency that is not done yet.'),
  claimed('Claimed', 'An agent (or someone in the app) holds it: work is in progress.');

  const ItemFlag(this.title, this.description);

  final String title;
  final String description;

  bool of(ItemDto item) => switch (this) {
    ready => item.ready,
    blocked => item.blocked,
    claimed => item.isClaimed,
  };
}

/// Client-side narrowing of the current view: free text, facet values and
/// flags. Values of one facet are alternatives (any of them); facets, flags
/// and text must all match.
final class BoardFilter {
  const BoardFilter({this.text = '', this.selected = const {}, this.flags = const {}});

  static const none = BoardFilter();

  /// Searched in id, title and branch, ignoring case.
  final String text;
  final Map<FilterFacet, Set<String>> selected;
  final Set<ItemFlag> flags;

  bool get isEmpty => text.trim().isEmpty && flags.isEmpty && selected.values.every((values) => values.isEmpty);

  Set<String> valuesFor(FilterFacet facet) => selected[facet] ?? const {};

  BoardFilter withText(String text) => BoardFilter(text: text, selected: selected, flags: flags);

  BoardFilter toggle(FilterFacet facet, String value) {
    final values = {...valuesFor(facet)};
    if (!values.remove(value)) values.add(value);
    return BoardFilter(text: text, selected: {...selected, facet: values}, flags: flags);
  }

  BoardFilter toggleFlag(ItemFlag flag) {
    final next = {...flags};
    if (!next.remove(flag)) next.add(flag);
    return BoardFilter(text: text, selected: selected, flags: next);
  }

  bool matches(ItemDto item, [Map<String, ItemDto> index = const {}]) {
    final query = text.trim().toLowerCase();
    if (query.isNotEmpty && ![item.id, item.title, ?item.branch].any((field) => field.toLowerCase().contains(query))) {
      return false;
    }
    for (final MapEntry(key: facet, value: wanted) in selected.entries) {
      if (wanted.isNotEmpty && !facet.valuesOf(item, index).any(wanted.contains)) return false;
    }
    return flags.every((flag) => flag.of(item));
  }

  /// The filter as conditions of a saved view (the YAML filter grammar), so
  /// that the server evaluates the same thing: one condition per facet, flag
  /// and the search text; all of them must hold.
  List<Object?> toConditions() {
    final query = text.trim();
    return [
      if (query.isNotEmpty)
        {
          'or': [
            for (final field in ['id', 'title', 'branch'])
              {
                field: {'contains': query},
              },
          ],
        },
      for (final MapEntry(key: facet, value: values) in selected.entries)
        if (values.isNotEmpty)
          switch (facet) {
            FilterFacet.person => {
              'or': [
                {'assignee': values.toList()},
                {'claimed_by': values.toList()},
              ],
            },
            FilterFacet.label => {'labels': values.toList()},
            _ => {facet.name: values.toList()},
          },
      for (final flag in flags) {flag.name: true},
    ];
  }

  /// [result] with the non-matching items left out; groups stay, even empty
  /// ones, so kanban columns do not jump around. [index] resolves parents.
  ViewResultDto apply(ViewResultDto result, [Map<String, ItemDto> index = const {}]) {
    if (isEmpty) return result;
    return ViewResultDto(
      id: result.id,
      name: result.name,
      layout: result.layout,
      groupBy: result.groupBy,
      fields: result.fields,
      columns: result.columns,
      hidden: result.hidden,
      groups: [
        for (final group in result.groups)
          ViewGroupDto(group.key, [
            for (final item in group.items)
              if (matches(item, index)) item,
          ]),
      ],
    );
  }

  /// Values to offer per facet, taken from [items] (and the current selection,
  /// so nothing selected disappears). Priorities and types keep the workflow
  /// order, the rest is alphabetical (epics by title).
  static Map<FilterFacet, List<String>> options(
    Iterable<ItemDto> items,
    WorkflowDto? workflow, {
    BoardFilter current = none,
    Map<String, ItemDto> index = const {},
  }) => {
    for (final facet in FilterFacet.values)
      facet: _ordered(
        facet,
        {...items.expand((item) => facet.valuesOf(item, index)), ...current.valuesFor(facet)},
        workflow,
        index,
      ),
  };

  static List<String> _ordered(
    FilterFacet facet,
    Set<String> values,
    WorkflowDto? workflow,
    Map<String, ItemDto> index,
  ) {
    final order = switch (facet) {
      FilterFacet.priority => workflow?.priorities,
      FilterFacet.type => workflow?.types,
      FilterFacet.milestone => workflow?.milestones.map((milestone) => milestone.id).toList(),
      _ => null,
    };
    int rank(String value) {
      final index = order?.indexOf(value) ?? -1;
      return index < 0 ? 1 << 30 : index;
    }

    return values.toList()..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : facet.describe(a, index).compareTo(facet.describe(b, index));
    });
  }
}
