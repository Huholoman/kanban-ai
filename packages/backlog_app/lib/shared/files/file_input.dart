import 'dart:async';

import 'package:flutter/foundation.dart';

import 'file_input_io.dart' if (dart.library.js_interop) 'file_input_web.dart' as platform;

/// A file chosen, dropped or pasted by the user, read into memory.
final class PickedFile {
  const PickedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// What happens with files over the page: something is dragged over it
/// ([dragging] true or false again), or files were dropped or pasted.
sealed class FileEvent {
  const FileEvent();
}

final class FileDragEvent extends FileEvent {
  const FileDragEvent({required this.dragging});

  final bool dragging;
}

final class FilesReceived extends FileEvent {
  const FilesReceived(this.files);

  final List<PickedFile> files;
}

/// The user's files: a dialog to choose them and those dropped onto or
/// pasted into the page. In the browser; elsewhere [canPick] is false and
/// nothing is dropped.
abstract interface class FileInput {
  /// The input of this platform ([testInput] when set).
  factory FileInput.platform() => testInput ?? platform.fileInput();

  /// Replaces the platform's input in tests.
  @visibleForTesting
  static FileInput? testInput;

  /// Whether [pick] opens a dialog.
  bool get canPick;

  /// Opens the system's dialog for choosing files; empty when cancelled.
  Future<List<PickedFile>> pick();

  /// Files dragged and dropped onto the page or pasted into it (with
  /// Ctrl+V) while listened to.
  Stream<FileEvent> events();
}
