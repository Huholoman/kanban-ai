import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
import '../../../shared/ui/ui.dart';
import '../application/board_filter.dart';

/// The board's filter toolbar: search, a Filters popover with a section per
/// facet, the readiness segments, one chip per active facet and the tally.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.filter,
    required this.options,
    required this.shown,
    required this.total,
    required this.onChanged,
    this.index = const {},
    this.counts = const {},
    this.onSaveAsView,
    this.searchFocus,
  });

  final BoardFilter filter;
  final Map<FilterFacet, List<String>> options;
  final int shown;
  final int total;
  final ValueChanged<BoardFilter> onChanged;

  /// All items by id, for showing epics by title.
  final Map<String, ItemDto> index;

  /// Items of the current view per facet value (see [BoardFilter.counts]),
  /// shown next to the values in the popover.
  final Map<FilterFacet, Map<String, int>> counts;

  /// Saves the filter as a view; null hides the button.
  final VoidCallback? onSaveAsView;

  /// Focus of the search field, so that a shortcut can jump to it.
  final FocusNode? searchFocus;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  static const _wideFrom = 900.0;

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideFrom;
        final tally = filter.isEmpty
            ? null
            : _Tally(shown: widget.shown, total: widget.total, onClear: () => widget.onChanged(BoardFilter.none));
        final controls = [
          _SearchField(
            controller: _search,
            focusNode: widget.searchFocus,
            width: (constraints.maxWidth - 24).clamp(120.0, 280.0),
            onChanged: (text) => widget.onChanged(filter.withText(text)),
          ),
          _FiltersButton(
            filter: filter,
            options: widget.options,
            counts: widget.counts,
            index: widget.index,
            matching: widget.shown,
            onChanged: widget.onChanged,
            onSaveAsView: widget.onSaveAsView,
          ),
          SegmentedChoice<ItemFlag>(
            segments: [
              for (final flag in ItemFlag.values)
                ChoiceSegment(
                  value: flag,
                  label: flag.title,
                  tooltip: flag.description,
                  key: ValueKey('filter-flag-${flag.name}'),
                ),
            ],
            selected: filter.flags,
            onToggle: (flag) => widget.onChanged(filter.toggleFlag(flag)),
          ),
          SegmentedChoice<ItemAge>(
            segments: [
              for (final age in ItemAge.values)
                ChoiceSegment(
                  value: age,
                  label: age.title,
                  tooltip: 'Changed in the last ${age.title}',
                  key: ValueKey('filter-age-${age.name}'),
                ),
            ],
            selected: {?filter.age},
            onToggle: (age) => widget.onChanged(filter.toggleAge(age)),
          ),
          for (final facet in FilterFacet.values)
            if (filter.valuesFor(facet).isNotEmpty)
              RemovableChip(
                key: ValueKey('chip-${facet.name}'),
                removeKey: ValueKey('chip-${facet.name}-remove'),
                text: _summary(facet),
                onRemove: () => widget.onChanged(_without(facet)),
              ),
        ];
        if (!wide) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [...controls, ?tally],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: controls),
            ),
            if (tally != null) ...[const SizedBox(width: 12), tally],
          ],
        );
      },
    );
  }

  BoardFilter _without(FilterFacet facet) {
    var next = widget.filter;
    for (final value in widget.filter.valuesFor(facet)) {
      next = next.toggle(facet, value);
    }
    return next;
  }

  /// "label: infra"; priorities forming a run in workflow order as "p0–p1".
  String _summary(FilterFacet facet) {
    final options = widget.options[facet] ?? const [];
    int rank(String value) {
      final at = options.indexOf(value);
      return at < 0 ? options.length : at;
    }

    final values = widget.filter.valuesFor(facet).toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    final ranks = values.map(rank).toList();
    final contiguous =
        values.length > 1 &&
        ranks.last < options.length &&
        [for (var i = 1; i < ranks.length; i++) ranks[i] - ranks[i - 1]].every((gap) => gap == 1);
    final text = facet == FilterFacet.priority && contiguous
        ? '${values.first}–${values.last}'
        : values.map((value) => facet == FilterFacet.label ? value : facet.describe(value, widget.index)).join(', ');
    return '${facet.name}: $text';
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.width, required this.onChanged, this.focusNode});

  final TextEditingController controller;
  final FocusNode? focusNode;
  final double width;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return SizedBox(
      width: width,
      height: BoardTokens.controlHeight,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          key: const ValueKey('filter-search'),
          controller: controller,
          focusNode: focusNode,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: 'Search id, title, branch',
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            prefixIcon: Icon(Icons.search, size: 16, color: tokens.muted),
            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: BoardTokens.controlHeight),
            suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: BoardTokens.controlHeight),
            suffixIcon: controller.text.isEmpty
                ? Center(widthFactor: 1, child: _KeyHint(tokens: tokens))
                : IconButton(
                    key: const ValueKey('filter-search-clear'),
                    tooltip: 'Clear search',
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _KeyHint extends StatelessWidget {
  const _KeyHint({required this.tokens});

  final BoardTokens tokens;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 6),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: tokens.borderStrong),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('/', style: TextStyle(fontSize: 11, color: tokens.muted)),
  );
}

/// "Filters" with the number of selected values; opens the popover.
class _FiltersButton extends StatelessWidget {
  const _FiltersButton({
    required this.filter,
    required this.options,
    required this.counts,
    required this.index,
    required this.matching,
    required this.onChanged,
    required this.onSaveAsView,
  });

  final BoardFilter filter;
  final Map<FilterFacet, List<String>> options;
  final Map<FilterFacet, Map<String, int>> counts;
  final Map<String, ItemDto> index;
  final int matching;
  final ValueChanged<BoardFilter> onChanged;
  final VoidCallback? onSaveAsView;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final active = filter.selected.values.fold<int>(0, (sum, values) => sum + values.length);
    return MenuAnchor(
      crossAxisUnconstrained: false,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(tokens.surface),
        side: WidgetStatePropertyAll(BorderSide(color: tokens.border)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(BoardTokens.radius))),
      ),
      menuChildren: [
        Builder(
          builder: (context) => _FiltersPanel(
            filter: filter,
            options: options,
            counts: counts,
            index: index,
            matching: matching,
            onChanged: onChanged,
            onSaveAsView: onSaveAsView == null
                ? null
                : () {
                    MenuController.maybeOf(context)?.close();
                    onSaveAsView!();
                  },
          ),
        ),
      ],
      builder: (context, menu, _) => SecondaryButton(
        key: const ValueKey('filter-button'),
        label: 'Filters',
        icon: Icons.filter_list,
        trailing: active > 0 ? CountBadge(active, key: const ValueKey('filter-badge')) : null,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// The popover: a section per facet that has options, then the tally and
/// "Save as view…".
class _FiltersPanel extends StatefulWidget {
  const _FiltersPanel({
    required this.filter,
    required this.options,
    required this.counts,
    required this.index,
    required this.matching,
    required this.onChanged,
    required this.onSaveAsView,
  });

  final BoardFilter filter;
  final Map<FilterFacet, List<String>> options;
  final Map<FilterFacet, Map<String, int>> counts;
  final Map<String, ItemDto> index;
  final int matching;
  final ValueChanged<BoardFilter> onChanged;
  final VoidCallback? onSaveAsView;

  @override
  State<_FiltersPanel> createState() => _FiltersPanelState();
}

class _FiltersPanelState extends State<_FiltersPanel> {
  /// A section shows this many values until "Show all"; longer ones also
  /// get a search box, so the other sections stay in reach.
  static const _shortList = 6;

  final _queries = <FilterFacet, String>{};
  final _expanded = <FilterFacet>{};

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final filter = widget.filter;
    final maxHeight = (MediaQuery.sizeOf(context).height - 120).clamp(240.0, 600.0);
    return SizedBox(
      width: 360,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Filters', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  LinkButton(
                    key: const ValueKey('filter-clear-all'),
                    label: 'Clear all',
                    onPressed: filter.selected.values.every((values) => values.isEmpty)
                        ? null
                        : () => widget.onChanged(BoardFilter(text: filter.text, flags: filter.flags, age: filter.age)),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final facet in FilterFacet.values)
                      if (widget.options[facet]?.isNotEmpty ?? false) _section(facet),
                  ],
                ),
              ),
            ),
            Divider(color: tokens.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.matching} ${widget.matching == 1 ? 'item matches' : 'items match'}',
                      style: TextStyle(color: tokens.muted),
                    ),
                  ),
                  if (widget.onSaveAsView != null && !filter.isEmpty)
                    SecondaryButton(
                      key: const ValueKey('filter-save'),
                      label: 'Save as view…',
                      onPressed: widget.onSaveAsView,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Priorities and types are few and short: a wrapped row of checkboxes.
  static bool _inline(FilterFacet facet) => facet == FilterFacet.priority || facet == FilterFacet.type;

  Widget _section(FilterFacet facet) {
    final all = widget.options[facet]!;
    final long = !_inline(facet) && all.length > _shortList;
    final query = (_queries[facet] ?? '').trim().toLowerCase();
    final selected = widget.filter.valuesFor(facet);
    final counts = widget.counts[facet] ?? const {};
    List<String> values;
    if (query.isNotEmpty) {
      values = [
        for (final value in all)
          if (facet.describe(value, widget.index).toLowerCase().contains(query)) value,
      ];
    } else if (long && !_expanded.contains(facet)) {
      // The short list: what is ticked, then the most frequent values.
      final ranked = [...all]
        ..sort((a, b) {
          final bySelection = (selected.contains(b) ? 1 : 0) - (selected.contains(a) ? 1 : 0);
          if (bySelection != 0) return bySelection;
          final byCount = (counts[b] ?? 0) - (counts[a] ?? 0);
          return byCount != 0 ? byCount : all.indexOf(a) - all.indexOf(b);
        });
      values = ranked.take(max(_shortList, selected.length)).toList();
    } else {
      values = all;
    }
    final hidden = all.length - values.length;
    return Column(
      key: ValueKey('filter-${facet.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(facet.title, padding: const EdgeInsets.only(top: 8, bottom: 4)),
        if (long)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SizedBox(
              height: BoardTokens.controlHeight,
              child: TextField(
                key: ValueKey('filter-${facet.name}-search'),
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  hintText: 'Search ${facet.title.toLowerCase()} (${all.length})',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onChanged: (text) => setState(() => _queries[facet] = text),
              ),
            ),
          ),
        if (_inline(facet))
          Wrap(spacing: 12, children: [for (final value in values) _option(facet, value)])
        else
          for (final value in values) _option(facet, value),
        if (long && query.isEmpty && (hidden > 0 || _expanded.contains(facet)))
          LinkButton(
            key: ValueKey('filter-${facet.name}-more'),
            label: _expanded.contains(facet) ? 'Show fewer' : 'Show all (${all.length})',
            accent: true,
            compact: true,
            onPressed: () => setState(() => _expanded.contains(facet) ? _expanded.remove(facet) : _expanded.add(facet)),
          ),
      ],
    );
  }

  Widget _option(FilterFacet facet, String value) {
    final tokens = BoardTokens.of(context);
    final count = widget.counts[facet]?[value];
    final compact = _inline(facet);
    return InkWell(
      borderRadius: BorderRadius.circular(BoardTokens.radiusSmall),
      onTap: () => widget.onChanged(widget.filter.toggle(facet, value)),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Checkbox(
            key: ValueKey('filter-${facet.name}-$value'),
            value: widget.filter.valuesFor(facet).contains(value),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (_) => widget.onChanged(widget.filter.toggle(facet, value)),
          ),
          if (compact)
            Padding(padding: const EdgeInsets.only(right: 4), child: Text(value))
          else ...[
            Expanded(child: Text(facet.describe(value, widget.index), overflow: TextOverflow.ellipsis)),
            if (count != null) Text('$count', style: TextStyle(color: tokens.muted)),
            const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

/// "14 of 41 shown · Clear".
class _Tally extends StatelessWidget {
  const _Tally({required this.shown, required this.total, required this.onClear});

  final int shown;
  final int total;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$shown of $total shown ·', style: TextStyle(color: tokens.muted)),
        LinkButton(
          key: const ValueKey('filter-clear'),
          label: 'Clear',
          accent: true,
          compact: true,
          onPressed: onClear,
        ),
      ],
    );
  }
}
