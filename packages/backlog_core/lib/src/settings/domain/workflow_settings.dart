import '../../shared/errors.dart';
import '../../workflow/domain/workflow.dart';
import 'config_draft.dart';

/// The lists of `backlog.yaml` that are edited entry by entry; [key] is the
/// top-level key, [singular] the key under `defaults` (and the word in
/// messages).
enum WorkflowList {
  statuses('statuses', 'status'),
  priorities('priorities', 'priority'),
  types('types', 'type'),
  milestones('milestones', 'milestone');

  const WorkflowList(this.key, this.singular);

  final String key;
  final String singular;

  /// Whether the list has a default value under `defaults`.
  bool get hasDefault => this != milestones;
}

/// One entry of a [WorkflowList] as the draft has it: a status with its
/// [category] (as written, maybe unknown) and [pickable], a milestone with
/// [title] and [due], a priority or type with just its [id].
final class WorkflowEntry {
  const WorkflowEntry(this.id, {this.category, this.pickable = false, this.title, this.due});

  final String id;
  final String? category;
  final bool pickable;
  final String? title;
  final String? due;
}

/// Typed reads and edits of the workflow sections of a `backlog.yaml`
/// [draft]: statuses, priorities, types, milestones, defaults, ids and
/// claims. Reads are lenient (a draft that does not validate still shows);
/// edits go through [ConfigDraft], so comments, key order and unknown keys
/// stay, and are checked as a whole only when saving. A list missing from
/// the file shows the built-in one, which the first edit writes out.
final class WorkflowSettings {
  WorkflowSettings(this.draft);

  final ConfigDraft draft;

  static final _standard = Workflow.standard();

  /// Whether [list] is absent from the file, so the built-in one applies
  /// (milestones: none).
  bool isBuiltIn(WorkflowList list) => draft.valueAt([list.key]) == null;

  /// The entries of [list] in order (the built-in ones when absent).
  List<WorkflowEntry> entries(WorkflowList list) {
    final value = draft.valueAt([list.key]);
    if (value == null) return _builtIn(list);
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map)
          WorkflowEntry(
            '${entry['id'] ?? ''}',
            category: entry['category']?.toString(),
            pickable: entry['pickable'] == true,
            title: entry['title']?.toString(),
            due: entry['due']?.toString(),
          )
        else
          WorkflowEntry('${entry ?? ''}'),
    ];
  }

  List<String> ids(WorkflowList list) => [for (final entry in entries(list)) entry.id];

  /// Adds [id] to [list]: a status with [category] after the last status of
  /// that category (or at [at]), anything else at the end (or at [at]).
  void add(WorkflowList list, String id, {StatusCategory category = StatusCategory.open, int? at}) {
    _checkNew(list, id);
    final current = entries(list);
    final position =
        at ?? (list == WorkflowList.statuses ? _afterLast(current, category) : current.length).clamp(0, current.length);
    final value = switch (list) {
      WorkflowList.statuses => {'id': id, 'category': category.name},
      WorkflowList.milestones => {'id': id},
      _ => id,
    };
    if (isBuiltIn(list)) {
      draft.set([list.key], [for (final entry in current) _value(list, entry)]..insert(position, value));
    } else {
      draft.insert([list.key], position, value);
    }
  }

  static int _afterLast(List<WorkflowEntry> statuses, StatusCategory category) {
    final order = StatusCategory.values;
    var position = 0;
    for (var i = 0; i < statuses.length; i++) {
      final rank = order.indexWhere((c) => c.name == statuses[i].category);
      if (rank >= 0 && rank <= category.index) position = i + 1;
    }
    return position;
  }

  /// Renames entry [index] of [list] to [id], and with it the references in
  /// the file: the default, the colour under `appearance` and, for a
  /// status, `on_enter` and `statuses` of the dispatcher's actions. Items
  /// keep the old value (`backlog lint` reports them).
  void rename(WorkflowList list, int index, String id) {
    final old = _entry(list, index).id;
    if (old == id) return;
    _checkNew(list, id);
    _materialize(list);
    if (draft.valueAt([list.key, index]) is Map) {
      draft.set([list.key, index, 'id'], id);
    } else {
      draft.set([list.key, index], id);
    }
    if (list.hasDefault && draft.valueAt(['defaults', list.singular]) == old) {
      draft.set(['defaults', list.singular], id);
    }
    final colours = draft.valueAt(['appearance', list.key]);
    if (colours is Map && colours.containsKey(old) && !colours.containsKey(id)) {
      final colour = colours[old];
      draft
        ..remove(['appearance', list.key, old])
        ..set(['appearance', list.key, id], colour);
    }
    if (list == WorkflowList.statuses) _renameInActions(old, id);
  }

  void _renameInActions(String old, String id) {
    final actions = draft.valueAt(['dispatcher', 'actions']);
    if (actions is! List) return;
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      if (action is! Map) continue;
      if (action['on_enter'] == old) draft.set(['dispatcher', 'actions', i, 'on_enter'], id);
      final statuses = action['statuses'];
      if (statuses is! List) continue;
      for (var j = 0; j < statuses.length; j++) {
        if (statuses[j] == old) draft.set(['dispatcher', 'actions', i, 'statuses', j], id);
      }
    }
  }

  /// Moves entry [index] of [list] to position [to].
  void move(WorkflowList list, int index, int to) {
    _entry(list, index);
    if (to < 0 || to >= entries(list).length) throw const InvalidInputException('It cannot move further.');
    if (to == index) return;
    _materialize(list);
    final value = draft.valueAt([list.key, index]);
    draft
      ..remove([list.key, index])
      ..insert([list.key], to, value);
  }

  /// Removes entry [index] of [list]. References to it (the default, the
  /// actions) stay; the review says when the file is no longer valid.
  void remove(WorkflowList list, int index) {
    _entry(list, index);
    _materialize(list);
    draft.remove([list.key, index]);
  }

  /// Sets the category of status [index].
  void setCategory(int index, StatusCategory category) {
    _entry(WorkflowList.statuses, index);
    _materialize(WorkflowList.statuses);
    draft.set([WorkflowList.statuses.key, index, 'category'], category.name);
  }

  /// Makes status [index] pickable or not (not pickable leaves the key out).
  void setPickable(int index, bool pickable) {
    _entry(WorkflowList.statuses, index);
    _materialize(WorkflowList.statuses);
    if (pickable) {
      draft.set([WorkflowList.statuses.key, index, 'pickable'], true);
    } else {
      draft.remove([WorkflowList.statuses.key, index, 'pickable']);
    }
  }

  /// Sets the [title] or [due] date of milestone [index]; empty removes it.
  void setMilestone(int index, {String? title, String? due}) {
    final entry = _entry(WorkflowList.milestones, index);
    final path = [WorkflowList.milestones.key, index];
    if (draft.valueAt(path) is! Map) {
      draft.set(path, {'id': entry.id, 'title': ?_text(title), 'due': ?_text(due)});
      return;
    }
    for (final (key, value) in [('title', title), ('due', due)]) {
      if (value == null) continue;
      if (_text(value) case final text?) {
        draft.set([...path, key], text);
      } else {
        draft.remove([...path, key]);
      }
    }
  }

  static String? _text(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// The default under `defaults` as written, null when absent.
  String? writtenDefault(WorkflowList list) => draft.valueAt(['defaults', list.singular])?.toString();

  /// The default that applies: the written one, else the first status or
  /// type, the middle priority (as [Workflow] does).
  String? effectiveDefault(WorkflowList list) {
    final written = writtenDefault(list);
    if (written != null) return written;
    if (isBuiltIn(list)) {
      return switch (list) {
        WorkflowList.statuses => _standard.defaultStatus,
        WorkflowList.priorities => _standard.defaultPriority,
        _ => _standard.defaultType,
      };
    }
    final ids = this.ids(list);
    if (ids.isEmpty) return null;
    return list == WorkflowList.priorities ? ids[ids.length ~/ 2] : ids.first;
  }

  /// Sets the default of [list] to [id] (one of its entries); null removes
  /// it, so that the rule of [effectiveDefault] applies.
  void setDefault(WorkflowList list, String? id) {
    if (!list.hasDefault) throw InvalidInputException('There is no default ${list.singular}.');
    if (id == null) {
      draft.remove(['defaults', list.singular]);
      return;
    }
    if (!ids(list).contains(id)) throw InvalidInputException('There is no ${list.singular} "$id".');
    draft.set(['defaults', list.singular], id);
  }

  String get idPrefix => draft.valueAt(['id', 'prefix'])?.toString() ?? _standard.idPrefix;

  void setIdPrefix(String prefix) {
    final value = prefix.trim();
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(value)) {
      throw InvalidInputException('The prefix must be letters and digits, starting with a letter: "$value".');
    }
    draft.set(['id', 'prefix'], value);
  }

  /// The length of the random part of new ids, null when not a number.
  int? get idLength => switch (draft.valueAt(['id', 'length'])) {
    null => _standard.idLength,
    final int length => length,
    _ => null,
  };

  void setIdLength(int length) {
    if (length < 3 || length > 12) throw InvalidInputException('The length must be between 3 and 12, not $length.');
    draft.set(['id', 'length'], length);
  }

  /// Minutes a claim lasts without heartbeat, null when not a number.
  int? get leaseMinutes => switch (draft.valueAt(['claims', 'lease_minutes'])) {
    null => _standard.claimLease.inMinutes,
    final int minutes => minutes,
    _ => null,
  };

  void setLeaseMinutes(int minutes) {
    if (minutes < 1) throw InvalidInputException('The lease must be at least one minute, not $minutes.');
    draft.set(['claims', 'lease_minutes'], minutes);
  }

  WorkflowEntry _entry(WorkflowList list, int index) {
    final all = entries(list);
    if (index < 0 || index >= all.length) throw InvalidInputException('There is no ${list.singular} ${index + 1}.');
    return all[index];
  }

  void _checkNew(WorkflowList list, String id) {
    if (id.isEmpty || id.trim() != id || id.contains(RegExp(r'\s'))) {
      throw InvalidInputException('A ${list.singular} id must not be empty or contain spaces: "$id".');
    }
    if (ids(list).contains(id)) throw InvalidInputException('There is a ${list.singular} "$id" already.');
  }

  /// Writes the built-in [list] into the file before its first edit.
  void _materialize(WorkflowList list) {
    if (!isBuiltIn(list)) return;
    draft.set([list.key], [for (final entry in _builtIn(list)) _value(list, entry)]);
  }

  static Object _value(WorkflowList list, WorkflowEntry entry) => switch (list) {
    WorkflowList.statuses => {'id': entry.id, 'category': ?entry.category, if (entry.pickable) 'pickable': true},
    WorkflowList.milestones => {'id': entry.id, 'title': ?entry.title, 'due': ?entry.due},
    _ => entry.id,
  };

  static List<WorkflowEntry> _builtIn(WorkflowList list) => switch (list) {
    WorkflowList.statuses => [
      for (final status in _standard.statuses)
        WorkflowEntry(status.id, category: status.category.name, pickable: status.pickable),
    ],
    WorkflowList.priorities => [for (final id in _standard.priorities) WorkflowEntry(id)],
    WorkflowList.types => [for (final id in _standard.types) WorkflowEntry(id)],
    WorkflowList.milestones => const [],
  };
}
