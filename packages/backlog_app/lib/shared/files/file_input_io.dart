import 'file_input.dart';

/// Outside the browser: no dialog, no drops (yet).
FileInput fileInput() => const _NoFileInput();

final class _NoFileInput implements FileInput {
  const _NoFileInput();

  @override
  bool get canPick => false;

  @override
  Future<List<PickedFile>> pick() async => const [];

  @override
  Stream<FileEvent> events() => const Stream.empty();
}
