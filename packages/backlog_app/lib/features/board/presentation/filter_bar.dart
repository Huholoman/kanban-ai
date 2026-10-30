import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../shared/tokens.dart';
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
          _Segments(filter: filter, onChanged: widget.onChanged),
          for (final facet in FilterFacet.values)
            if (filter.valuesFor(facet).isNotEmpty)
              _FacetChip(facet: facet, text: _summary(facet), onRemove: () => widget.onChanged(_without(facet))),
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
      builder: (context, menu, _) => OutlinedButton.icon(
        key: const ValueKey('filter-button'),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.filter_list, size: 16),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Filters'),
            if (active > 0) ...[const SizedBox(width: 6), _Badge(count: active, tokens: tokens)],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.tokens});

  final int count;
  final BoardTokens tokens;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('filter-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(9)),
    child: Text(
      '$count',
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tokens.onAccent),
    ),
  );
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
  /// Labels beyond this many get their own search box.
  static const _searchableFrom = 8;

  String _labelQuery = '';

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
                  TextButton(
                    key: const ValueKey('filter-clear-all'),
                    onPressed: filter.selected.values.every((values) => values.isEmpty)
                        ? null
                        : () => widget.onChanged(BoardFilter(text: filter.text, flags: filter.flags)),
                    child: const Text('Clear all'),
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
                    OutlinedButton(
                      key: const ValueKey('filter-save'),
                      onPressed: widget.onSaveAsView,
                      child: const Text('Save as view…'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(FilterFacet facet) {
    final tokens = BoardTokens.of(context);
    var values = widget.options[facet]!;
    final searchable = facet == FilterFacet.label && values.length >= _searchableFrom;
    final query = _labelQuery.trim().toLowerCase();
    if (searchable && query.isNotEmpty) {
      values = [
        for (final value in values)
          if (value.toLowerCase().contains(query)) value,
      ];
    }
    return Column(
      key: ValueKey('filter-${facet.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            facet.title.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: tokens.muted),
          ),
        ),
        if (searchable)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SizedBox(
              height: BoardTokens.controlHeight,
              child: TextField(
                key: const ValueKey('filter-label-search'),
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  hintText: 'Search labels (${widget.options[facet]!.length})',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onChanged: (text) => setState(() => _labelQuery = text),
              ),
            ),
          ),
        if (facet == FilterFacet.priority)
          Wrap(spacing: 12, children: [for (final value in values) _option(facet, value)])
        else
          for (final value in values) _option(facet, value),
      ],
    );
  }

  Widget _option(FilterFacet facet, String value) {
    final tokens = BoardTokens.of(context);
    final count = widget.counts[facet]?[value];
    final compact = facet == FilterFacet.priority;
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

/// Ready | Blocked | Claimed as one bordered group.
class _Segments extends StatelessWidget {
  const _Segments({required this.filter, required this.onChanged});

  final BoardFilter filter;
  final ValueChanged<BoardFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final radius = BorderRadius.circular(BoardTokens.radiusSmall);
    return Container(
      height: BoardTokens.controlHeight,
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderStrong),
        borderRadius: radius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (position, flag) in ItemFlag.values.indexed) ...[
            if (position > 0) VerticalDivider(width: 1, color: tokens.borderStrong),
            _Segment(flag: flag, pressed: filter.flags.contains(flag), onTap: () => onChanged(filter.toggleFlag(flag))),
          ],
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.flag, required this.pressed, required this.onTap});

  final ItemFlag flag;
  final bool pressed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Tooltip(
      message: flag.description,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: pressed ? tokens.accentSoft : tokens.surface,
        child: InkWell(
          key: ValueKey('filter-flag-${flag.name}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                flag.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: pressed ? FontWeight.w600 : FontWeight.w400,
                  color: pressed ? tokens.accent : tokens.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A removable chip for one facet, e.g. "label: infra".
class _FacetChip extends StatelessWidget {
  const _FacetChip({required this.facet, required this.text, required this.onRemove});

  final FilterFacet facet;
  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return Container(
      key: ValueKey('chip-${facet.name}'),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(color: tokens.chip, borderRadius: BorderRadius.circular(BoardTokens.controlHeight)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(text, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          IconButton(
            key: ValueKey('chip-${facet.name}-remove'),
            tooltip: 'Remove',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            iconSize: 12,
            color: tokens.muted,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
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
        TextButton(
          key: const ValueKey('filter-clear'),
          style: TextButton.styleFrom(
            foregroundColor: tokens.accent,
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onClear,
          child: const Text('Clear'),
        ),
      ],
    );
  }
}
