import 'package:backlog_api/backlog_api.dart';

/// Item fields the board can be narrowed by. Status is left out on purpose:
/// views show it as columns or groups.
enum FilterFacet {
  label('Labels'),
  type('Type'),
  priority('Priority'),
  milestone('Milestone'),
  person('People');

  const FilterFacet(this.title);

  final String title;

  /// Values of this facet on [item]; people are the assignee and whoever
  /// holds the claim.
  Iterable<String> valuesOf(ItemDto item) => switch (this) {
    label => item.labels,
    type => [item.type],
    priority => [item.priority],
    milestone => [?item.milestone],
    person => {?item.assignee, ?item.claim?.agent},
  };
}

/// Planning state an item can be required to have.
enum ItemFlag {
  ready('Ready'),
  blocked('Blocked'),
  claimed('Claimed');

  const ItemFlag(this.title);

  final String title;

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

  bool matches(ItemDto item) {
    final query = text.trim().toLowerCase();
    if (query.isNotEmpty && ![item.id, item.title, ?item.branch].any((field) => field.toLowerCase().contains(query))) {
      return false;
    }
    for (final MapEntry(key: facet, value: wanted) in selected.entries) {
      if (wanted.isNotEmpty && !facet.valuesOf(item).any(wanted.contains)) return false;
    }
    return flags.every((flag) => flag.of(item));
  }

  /// [result] with the non-matching items left out; groups stay, even empty
  /// ones, so kanban columns do not jump around.
  ViewResultDto apply(ViewResultDto result) {
    if (isEmpty) return result;
    return ViewResultDto(
      id: result.id,
      name: result.name,
      layout: result.layout,
      groupBy: result.groupBy,
      fields: result.fields,
      hidden: result.hidden,
      groups: [for (final group in result.groups) ViewGroupDto(group.key, group.items.where(matches).toList())],
    );
  }

  /// Values to offer per facet, taken from [items] (and the current selection,
  /// so nothing selected disappears). Priorities and types keep the workflow
  /// order, the rest is alphabetical.
  static Map<FilterFacet, List<String>> options(
    Iterable<ItemDto> items,
    WorkflowDto? workflow, {
    BoardFilter current = none,
  }) => {
    for (final facet in FilterFacet.values)
      facet: _ordered(facet, {...items.expand(facet.valuesOf), ...current.valuesFor(facet)}, workflow),
  };

  static List<String> _ordered(FilterFacet facet, Set<String> values, WorkflowDto? workflow) {
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
      return byRank != 0 ? byRank : a.compareTo(b);
    });
  }
}
