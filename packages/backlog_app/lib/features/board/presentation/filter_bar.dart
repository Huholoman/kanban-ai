import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../application/board_filter.dart';

/// Search field, a menu per facet, flag chips and a reset, above the board.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.filter,
    required this.options,
    required this.shown,
    required this.total,
    required this.onChanged,
    this.index = const {},
  });

  final BoardFilter filter;
  final Map<FilterFacet, List<String>> options;
  final int shown;
  final int total;
  final ValueChanged<BoardFilter> onChanged;

  /// All items by id, for showing epics by title.
  final Map<String, ItemDto> index;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  late final _search = TextEditingController(text: widget.filter.text);

  @override
  void didUpdateWidget(FilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter.text != _search.text) _search.text = widget.filter.text;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 240,
            child: TextField(
              key: const ValueKey('filter-search'),
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search id, title, branch',
                prefixIcon: const Icon(Icons.search, size: 20),
                border: const OutlineInputBorder(),
                suffixIcon: filter.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => widget.onChanged(filter.withText('')),
                      ),
              ),
              onChanged: (text) => widget.onChanged(filter.withText(text)),
            ),
          ),
          for (final facet in FilterFacet.values)
            if (widget.options[facet]?.isNotEmpty ?? false)
              _FacetMenu(
                index: widget.index,
                facet: facet,
                options: widget.options[facet]!,
                selected: filter.valuesFor(facet),
                onToggle: (value) => widget.onChanged(filter.toggle(facet, value)),
              ),
          for (final flag in ItemFlag.values)
            FilterChip(
              key: ValueKey('filter-flag-${flag.name}'),
              label: Text(flag.title),
              tooltip: flag.description,
              selected: filter.flags.contains(flag),
              onSelected: (_) => widget.onChanged(filter.toggleFlag(flag)),
            ),
          if (!filter.isEmpty) ...[
            TextButton.icon(
              key: const ValueKey('filter-clear'),
              onPressed: () => widget.onChanged(BoardFilter.none),
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Clear'),
            ),
            Text(
              '${widget.shown} of ${widget.total}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// A chip that opens a checklist of one facet's values and sums up the
/// selection in its label.
class _FacetMenu extends StatelessWidget {
  const _FacetMenu({
    required this.facet,
    required this.options,
    required this.selected,
    required this.onToggle,
    this.index = const {},
  });

  final Map<String, ItemDto> index;

  final FilterFacet facet;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  String get _label => switch (selected.length) {
    0 => facet.title,
    1 || 2 => '${facet.title}: ${selected.map((value) => facet.describe(value, index)).join(', ')}',
    _ => '${facet.title}: ${selected.length}',
  };

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final option in options)
        CheckboxMenuButton(
          key: ValueKey('filter-${facet.name}-$option'),
          value: selected.contains(option),
          closeOnActivate: false,
          onChanged: (_) => onToggle(option),
          child: Text(facet.describe(option, index)),
        ),
    ],
    builder: (context, menu, _) => FilterChip(
      key: ValueKey('filter-${facet.name}'),
      showCheckmark: false,
      selected: selected.isNotEmpty,
      label: Row(mainAxisSize: MainAxisSize.min, children: [Text(_label), const Icon(Icons.arrow_drop_down, size: 18)]),
      onSelected: (_) => menu.isOpen ? menu.close() : menu.open(),
    ),
  );
}
