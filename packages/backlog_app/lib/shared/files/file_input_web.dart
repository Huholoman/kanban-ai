import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_input.dart';

/// In the browser: a hidden `<input type="file">` and the page's `drop` and
/// `paste` events.
FileInput fileInput() => const _BrowserFileInput();

final class _BrowserFileInput implements FileInput {
  const _BrowserFileInput();

  @override
  bool get canPick => true;

  @override
  Future<List<PickedFile>> pick() {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..multiple = true;
    final chosen = Completer<List<PickedFile>>();
    void complete(Future<List<PickedFile>> files) {
      if (!chosen.isCompleted) chosen.complete(files);
    }

    input.onchange = ((web.Event _) => complete(_read(input.files))).toJS;
    input.addEventListener('cancel', ((web.Event _) => complete(Future.value(const []))).toJS);
    input.click();
    return chosen.future;
  }

  @override
  Stream<FileEvent> events() {
    late final StreamController<FileEvent> controller;
    final listeners = <(String, JSFunction)>[];
    var depth = 0; // dragenter/dragleave pairs of nested elements

    bool carriesFiles(web.DragEvent event) =>
        event.dataTransfer?.types.toDart.any((type) => type.toDart == 'Files') ?? false;

    void listen(String type, void Function(web.Event event) handle) {
      final listener = handle.toJS;
      listeners.add((type, listener));
      web.window.addEventListener(type, listener);
    }

    controller = StreamController<FileEvent>(
      onListen: () {
        listen('dragenter', (event) {
          if (!carriesFiles(event as web.DragEvent)) return;
          event.preventDefault();
          if (depth++ == 0) controller.add(const FileDragEvent(dragging: true));
        });
        listen('dragover', (event) {
          if (!carriesFiles(event as web.DragEvent)) return;
          event.preventDefault(); // allows the drop
          event.dataTransfer?.dropEffect = 'copy';
        });
        listen('dragleave', (event) {
          if (!carriesFiles(event as web.DragEvent)) return;
          if (depth > 0 && --depth == 0) controller.add(const FileDragEvent(dragging: false));
        });
        listen('drop', (event) {
          final drop = event as web.DragEvent;
          if (!carriesFiles(drop)) return;
          drop.preventDefault(); // the browser would open the file instead
          depth = 0;
          controller.add(const FileDragEvent(dragging: false));
          unawaited(_read(drop.dataTransfer?.files).then((files) => controller.add(FilesReceived(files))));
        });
        listen('paste', (event) {
          final files = (event as web.ClipboardEvent).clipboardData?.files;
          if (files == null || files.length == 0) return; // text goes to the focused field
          event.preventDefault();
          unawaited(_read(files).then((files) => controller.add(FilesReceived(files))));
        });
      },
      onCancel: () {
        for (final (type, listener) in listeners) {
          web.window.removeEventListener(type, listener);
        }
        listeners.clear();
      },
    );
    return controller.stream;
  }

  static Future<List<PickedFile>> _read(web.FileList? files) async {
    if (files == null) return const [];
    return [
      for (var i = 0; i < files.length; i++)
        if (files.item(i) case final file?)
          PickedFile(file.name, (await file.arrayBuffer().toDart).toDart.asUint8List()),
    ];
  }
}
