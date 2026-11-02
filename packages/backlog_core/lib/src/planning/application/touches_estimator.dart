import '../../items/application/item_service.dart';
import '../domain/touches_estimate.dart';

/// Suggests the `touches` of an item (`touches.suggest`): the model gets
/// the item's description and a map of the code repository, its answer is
/// checked against the repository's files. Nothing is saved; a person
/// confirms or corrects the suggestion.
final class TouchesEstimator {
  TouchesEstimator({required ItemService items, required RepoFiles files, required TouchesModel model})
    : _items = items,
      _files = files,
      _model = model;

  final ItemService _items;
  final RepoFiles _files;
  final TouchesModel _model;

  Future<TouchesEstimate> estimate(String reference) async {
    final item = await _items.get(reference);
    final files = await _files.list();
    final answer = await _model.ask(item, TouchesPrompt.render(item, TouchesPrompt.repoMap(files)));
    final (:touches, :rejected) = TouchesPrompt.parse(answer, files: files);
    return TouchesEstimate(item: item, touches: touches, rejected: rejected, answer: answer);
  }
}
