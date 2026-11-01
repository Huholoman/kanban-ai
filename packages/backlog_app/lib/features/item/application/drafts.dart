/// Keeps text written but not sent yet, so that leaving an item (another
/// item, another tab, a reload) does not lose it. A convenience only: it may
/// forget at any time.
abstract interface class DraftStore {
  String? read(String key);

  /// Keeps [text] under [key]; blank text forgets the key.
  void write(String key, String text);
}

/// Keeps drafts for the lifetime of the app (tests, desktop).
final class InMemoryDraftStore implements DraftStore {
  final _drafts = <String, String>{};

  @override
  String? read(String key) => _drafts[key];

  @override
  void write(String key, String text) => text.trim().isEmpty ? _drafts.remove(key) : _drafts[key] = text;
}

/// The drafts of one project (null: the single backlog).
final class Drafts {
  const Drafts(this.store, this.project);

  final DraftStore store;
  final String? project;

  /// The same store for another project.
  Drafts of(String? project) => Drafts(store, project);

  /// The unsent reply in the discussion of [item]; empty without one.
  String reply(String item) => store.read(_replyKey(item)) ?? '';

  /// Keeps [text] as the reply to [item]; blank text forgets it.
  void keepReply(String item, String text) => store.write(_replyKey(item), text);

  String _replyKey(String item) => '${project == null ? '' : '$project/'}$item/reply';
}
