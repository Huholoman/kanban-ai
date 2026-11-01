import '../features/item/application/drafts.dart';

/// Outside the browser drafts last as long as the app.
DraftStore draftStore() => InMemoryDraftStore();
