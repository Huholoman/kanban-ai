import '../../shared/errors.dart';
import '../../views/domain/view.dart';
import 'config_draft.dart';

/// Typed reads and edits of the draft of one view (`views/<id>.yaml`, §6):
/// name, section, layout, grouping, columns, sort, extra fields, filter and
/// pinned. An empty input removes the key; the review checks the whole
/// view.
final class ViewSettings {
  ViewSettings(this.draft);

  final ConfigDraft draft;

  /// Keys edited as one line of text.
  static const textKeys = {'name', 'section', 'group_by'};

  /// Keys edited as comma-separated lists.
  static const listKeys = {'columns', 'sort', 'fields'};

  /// The value of [key] as typed back: lists comma-separated, a filter in
  /// YAML flow style; null when absent.
  String? text(String key) => switch (draft.valueAt([key])) {
    null => null,
    final List<Object?> list when listKeys.contains(key) => list.join(', '),
    final value => formatConfigValue(value),
  };

  ViewLayout get layout => ViewLayout.tryParse('${draft.valueAt(['layout']) ?? 'list'}') ?? ViewLayout.list;

  bool get pinned => draft.valueAt(['pinned']) == true;

  void setText(String key, String input) {
    if (!textKeys.contains(key)) throw InvalidInputException('$key is not a text of a view.');
    final value = input.trim();
    _set(key, value.isEmpty ? null : value);
  }

  void setLayout(ViewLayout layout) => draft.set(['layout'], layout.name);

  /// Sets [key] (`columns`, `sort` or `fields`) from comma-separated values;
  /// columns must not repeat, sort keys are fields with an optional `-`.
  void setList(String key, String input) {
    if (!listKeys.contains(key)) throw InvalidInputException('$key is not a list of a view.');
    final values = [
      for (final part in input.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (key == 'columns' && values.toSet().length != values.length) {
      throw const InvalidInputException('Columns must not repeat.');
    }
    if (key == 'sort') {
      for (final value in values) {
        if (SortKey.parse(value).field.isEmpty || value.contains(' ')) {
          throw InvalidInputException('"$value" is not a sort key like priority or -updated.');
        }
      }
    }
    _set(key, values.isEmpty ? null : values);
  }

  /// Sets the filter from a YAML mapping or list in flow style, e.g.
  /// `{milestone: v0.3, category: {not: [done]}}`.
  void setFilter(String input) {
    if (input.trim().isEmpty) {
      _set('filter', null);
      return;
    }
    final value = parseConfigValue(input);
    if (value is! Map && value is! List) {
      throw InvalidInputException('A filter is a mapping like {status: todo}, not "${input.trim()}".');
    }
    _set('filter', value);
  }

  void setPinned(bool pinned) => _set('pinned', pinned ? true : null);

  void _set(String key, Object? value) {
    if (value == null) {
      draft.remove([key]);
    } else {
      draft.set([key], value);
    }
  }
}
