import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/workflow.dart';
import '../domain/checklist.dart';
import '../domain/discussion.dart';
import '../domain/item.dart';
import '../domain/item_body.dart';
import '../domain/item_id.dart';
import '../domain/item_repository.dart';
import '../domain/item_time.dart';
import 'field_change.dart';

/// Input for [ItemService.create]. References (`parent`, `dependsOn`, …) may be
/// shortened ids; they are resolved against existing items.
final class NewItem {
  const NewItem({
    required this.title,
    this.type,
    this.status,
    this.priority,
    this.milestone,
    this.parent,
    this.dependsOn = const [],
    this.related = const [],
    this.labels = const [],
    this.docs = const [],
    this.touches = const [],
    this.assignee,
    this.branch,
    this.pr,
    this.body = '',
  });

  final String title;
  final String? type;
  final String? status;
  final String? priority;
  final String? milestone;
  final String? parent;
  final List<String> dependsOn;
  final List<String> related;
  final List<String> labels;
  final List<String> docs;

  /// Paths or globs in the code repository the work will change.
  final List<String> touches;
  final String? assignee;
  final String? branch;
  final String? pr;
  final String body;
}

/// Use cases for reading, creating and editing items.
final class ItemService {
  ItemService({
    required ItemRepository repository,
    required Workflow workflow,
    required IdGenerator ids,
    required Clock clock,
  }) : _repository = repository,
       _workflow = workflow,
       _ids = ids,
       _clock = clock;

  final ItemRepository _repository;
  final Workflow _workflow;
  final IdGenerator _ids;
  final Clock _clock;

  Future<List<Item>> all() async => (await _repository.load()).items;

  Future<Item> get(String reference) async => find((await _repository.load()).items, reference);

  Future<String?> locate(String reference) async => _repository.locationOf((await get(reference)).id);

  /// Where item [id] is stored. Without reading the items again when they
  /// were just loaded (e.g. by a snapshot that found [id]).
  Future<String?> locationOf(ItemId id) => _repository.locationOf(id);

  Future<Item> create(NewItem draft) async {
    final items = (await _repository.load()).items;
    final known = {for (final item in items) item.id};
    final now = ItemTime.format(_clock.now());

    final item = Item(
      id: _freshId(known),
      title: draft.title.trim(),
      type: _checkType(draft.type ?? _workflow.defaultType),
      status: _checkStatus(draft.status ?? _workflow.defaultStatus),
      priority: _checkPriority(draft.priority ?? _workflow.defaultPriority),
      milestone: draft.milestone == null ? null : _checkMilestone(draft.milestone!),
      parent: draft.parent == null ? null : ItemReference.resolve(draft.parent!, known),
      dependsOn: _distinct(draft.dependsOn.map((r) => ItemReference.resolve(r, known))),
      related: _distinct(draft.related.map((r) => ItemReference.resolve(r, known))),
      labels: _distinct(draft.labels),
      docs: _distinct(draft.docs),
      touches: _distinct(draft.touches),
      assignee: draft.assignee,
      branch: draft.branch,
      pr: draft.pr,
      created: now,
      updated: now,
      body: draft.body,
    );
    await _repository.save(item);
    return item;
  }

  /// Applies [changes] in order, replaces the Markdown [body] when given and
  /// bumps `updated` unless a change sets it or nothing changed.
  Future<Item> update(String reference, Iterable<FieldChange> changes, {String? body}) async {
    final items = (await _repository.load()).items;
    final known = {for (final item in items) item.id};
    final original = find(items, reference);

    var item = original;
    var setsUpdated = false;
    for (final change in changes) {
      item = _apply(item, change, known);
      setsUpdated |= change.field == 'updated';
    }
    if (body != null) item = item.copyWith(body: body);
    if (!setsUpdated) {
      item = item.touchedSince(original, _clock.now());
    }
    await _repository.save(item);
    return item;
  }

  /// Moves finished items (status of category done) into the archive: the
  /// ones [references] name, each of which must be finished, or else every
  /// finished item unchanged for at least [olderThan]. Returns the items
  /// that moved (with [dryRun] that would move), oldest first.
  Future<List<Item>> archive({
    List<String> references = const [],
    Duration olderThan = const Duration(days: 30),
    bool dryRun = false,
  }) async {
    final catalog = await _repository.load();
    final List<Item> selected;
    if (references.isEmpty) {
      final before = _clock.now().subtract(olderThan);
      selected = [
        for (final item in catalog.items)
          if (_finished(item) && !catalog.archived.contains(item.id))
            if (item.updatedAt ?? item.createdAt case final changed? when !changed.isAfter(before)) item,
      ];
    } else {
      selected = {for (final reference in references) find(catalog.items, reference)}.toList();
      for (final item in selected) {
        if (!_finished(item)) throw InvalidInputException('${item.id} is not finished (status ${item.status}).');
      }
      selected.removeWhere((item) => catalog.archived.contains(item.id));
    }
    selected.sort((a, b) => _changedAt(a).compareTo(_changedAt(b)));
    if (!dryRun) {
      for (final item in selected) {
        await _repository.setArchived(item.id, archived: true);
      }
    }
    return selected;
  }

  /// Moves an archived item back among the others; false when it was not
  /// archived.
  Future<bool> restore(String reference) async {
    final catalog = await _repository.load();
    final item = find(catalog.items, reference);
    if (!catalog.archived.contains(item.id)) return false;
    await _repository.setArchived(item.id, archived: false);
    return true;
  }

  bool _finished(Item item) => _workflow.categoryOf(item.status) == StatusCategory.done;

  static DateTime _changedAt(Item item) => item.updatedAt ?? item.createdAt ?? DateTime.utc(0);

  /// Adds a comment by [author] to the item's discussion (the `## Discussion`
  /// section of its body); a [question] makes the item wait for a person
  /// until someone else comments; a [note] neither answers it nor wakes the
  /// item's agent; a [review] records the verdict of a review of the item's
  /// work (optionally of [commit]), which neither answers nor wakes either.
  Future<Item> comment(
    String reference, {
    required String author,
    required String text,
    bool question = false,
    bool note = false,
    ReviewVerdict? review,
    String? commit,
  }) async {
    final item = await get(reference);
    final comment = Comment(
      author: author,
      at: _clock.now(),
      text: text,
      question: question,
      note: note,
      review: review,
      commit: commit,
    );
    return update(item.id.value, const [], body: Discussion.append(item.body, comment));
  }

  /// Replaces the description of the item (its body above `## Discussion`)
  /// with [text], or with a [section] only the content of the section
  /// headed `## <section>` (added when missing); the discussion stays.
  Future<Item> describe(String reference, String text, {String? section}) async {
    final item = await get(reference);
    if (section != null && !ItemBody.isSectionName(section)) {
      throw InvalidInputException(
        '"$section" is not a section of the description (not empty, one line, not the discussion).',
      );
    }
    if (!ItemBody.isDescription(text)) {
      throw InvalidInputException(
        'The text contains a "## Discussion" heading; give only the description, without the discussion.',
      );
    }
    return update(
      item.id.value,
      const [],
      body: section == null
          ? ItemBody.withDescription(item.body, text)
          : ItemBody.withSection(item.body, section, text),
    );
  }

  /// Checks ([done]) or unchecks the checklist items of the item that
  /// [selectors] name (numbers or text, see [Checklist.select]), changing
  /// nothing else in its file. The file is written only when a box changes.
  Future<ChecklistUpdate> check(String reference, List<String> selectors, {bool done = true}) async {
    final item = await get(reference);
    final entries = Checklist.entriesOf(item.body);
    if (entries.isEmpty) throw NotFoundException('${item.id} has no checklist (`- [ ]` lines in its body).');
    final selected = <ChecklistEntry>{for (final selector in selectors) Checklist.select(entries, selector)};
    final changed = selected.where((entry) => entry.done != done).toList()..sort((a, b) => a.number - b.number);
    if (changed.isEmpty) return ChecklistUpdate(item, selected.toList(), changed: const []);
    final updated = await update(item.id.value, const [], body: Checklist.mark(item.body, changed, done: done));
    return ChecklistUpdate(updated, selected.toList(), changed: [for (final entry in changed) entry.number]);
  }

  Item find(List<Item> items, String reference) {
    final id = ItemReference.resolve(reference, items.map((i) => i.id));
    return items.firstWhere((item) => item.id == id);
  }

  Item _apply(Item item, FieldChange change, Set<ItemId> known) {
    ItemId resolve(String reference) {
      final id = ItemReference.resolve(reference, known);
      if (id == item.id) {
        throw InvalidInputException('${item.id} cannot reference itself in "${change.field}".');
      }
      return id;
    }

    String? optional(String Function(String value) check) => change.clears ? null : check(_scalar(change));

    // Removing takes an id as it is in the list, so that a reference to an
    // item that no longer exists can be removed.
    ItemId Function(String) listed(List<ItemId> current) => change.op == ChangeOp.remove
        ? (reference) => current.firstWhere((id) => id.value == reference, orElse: () => resolve(reference))
        : resolve;

    return switch (change.field) {
      'id' => throw const InvalidInputException('The id of an item cannot be changed.'),
      'title' => item.copyWith(title: _required(change)),
      'type' => item.copyWith(type: _checkType(_required(change))),
      'status' => item.copyWith(status: _checkStatus(_required(change))),
      'priority' => item.copyWith(priority: _checkPriority(_required(change))),
      'milestone' => item.copyWith(milestone: () => optional(_checkMilestone)),
      'parent' => item.copyWith(parent: () => change.clears ? null : resolve(_scalar(change))),
      'depends_on' => item.copyWith(dependsOn: _applyList(item.dependsOn, change, listed(item.dependsOn))),
      'related' => item.copyWith(related: _applyList(item.related, change, listed(item.related))),
      'labels' => item.copyWith(labels: _applyList(item.labels, change, (v) => v)),
      'docs' => item.copyWith(docs: _applyList(item.docs, change, (v) => v)),
      'touches' => item.copyWith(touches: _applyList(item.touches, change, (v) => v)),
      'assignee' => item.copyWith(assignee: () => optional((v) => v)),
      'branch' => item.copyWith(branch: () => optional((v) => v)),
      'pr' => item.copyWith(pr: () => optional((v) => v)),
      'created' => item.copyWith(created: () => optional((v) => v)),
      'updated' => item.copyWith(updated: () => optional((v) => v)),
      _ => item.copyWith(extra: _applyExtra(item.extra, change)),
    };
  }

  Map<String, Object?> _applyExtra(Map<String, Object?> extra, FieldChange change) {
    final result = Map<String, Object?>.of(extra);
    if (change.clears) {
      result.remove(change.field);
    } else if (change.op == ChangeOp.set) {
      result[change.field] = change.value;
    } else {
      final current = switch (extra[change.field]) {
        null => <String>[],
        final List<Object?> list => list.map((v) => '$v').toList(),
        final Object value => ['$value'],
      };
      result[change.field] = _applyList(current, change, (v) => v);
    }
    return result;
  }

  List<T> _applyList<T>(List<T> current, FieldChange change, T Function(String) convert) {
    final values = change.values.map(convert).toList();
    return switch (change.op) {
      ChangeOp.set => _distinct(values),
      ChangeOp.add => _distinct([...current, ...values]),
      ChangeOp.remove => current.where((v) => !values.contains(v)).toList(),
    };
  }

  ItemId _freshId(Set<ItemId> known) {
    for (var attempt = 0; attempt < 50; attempt++) {
      final id = _ids.next();
      if (!known.contains(id)) return id;
    }
    throw const InvalidInputException('Could not allocate a free id; increase id.length in backlog.yaml.');
  }

  String _required(FieldChange change) {
    if (change.op != ChangeOp.set) {
      throw InvalidInputException('"${change.field}" is not a list; use ${change.field}=value.');
    }
    if (change.value.isEmpty) {
      throw InvalidInputException('"${change.field}" cannot be empty.');
    }
    return change.value;
  }

  String _scalar(FieldChange change) {
    if (change.op != ChangeOp.set) {
      throw InvalidInputException('"${change.field}" is not a list; use ${change.field}=value.');
    }
    return change.value;
  }

  String _checkType(String type) => _workflow.hasType(type)
      ? type
      : throw InvalidInputException('Unknown type "$type" (known: ${_workflow.types.join(', ')}).');

  String _checkStatus(String status) => _workflow.status(status) != null
      ? status
      : throw InvalidInputException(
          'Unknown status "$status" (known: ${_workflow.statuses.map((s) => s.id).join(', ')}).',
        );

  String _checkPriority(String priority) => _workflow.hasPriority(priority)
      ? priority
      : throw InvalidInputException('Unknown priority "$priority" (known: ${_workflow.priorities.join(', ')}).');

  String _checkMilestone(String milestone) => _workflow.acceptsMilestone(milestone)
      ? milestone
      : throw InvalidInputException(
          'Unknown milestone "$milestone" (known: ${_workflow.milestones.map((m) => m.id).join(', ')}).',
        );

  static List<T> _distinct<T>(Iterable<T> values) => values.toSet().toList();
}

/// What [ItemService.check] did: the item as saved, the entries named and
/// the numbers of those whose box changed.
final class ChecklistUpdate {
  const ChecklistUpdate(this.item, this.selected, {required this.changed});

  final Item item;
  final List<ChecklistEntry> selected;
  final List<int> changed;

  List<ChecklistEntry> get entries => Checklist.entriesOf(item.body);
}
