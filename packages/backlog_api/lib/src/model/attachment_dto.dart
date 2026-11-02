import 'json.dart';

/// A file attached to an item (`attachments` of the detail).
final class AttachmentDto {
  const AttachmentDto({required this.name, required this.size, this.modified});

  factory AttachmentDto.fromJson(Json json) {
    final modified = json.optionalString('modified');
    return AttachmentDto(
      name: json.string('name'),
      size: json.integer('size'),
      modified: modified == null ? null : DateTime.parse(modified),
    );
  }

  /// The largest attachment the server accepts, in bytes (32 MiB).
  static const maxSize = 32 * 1024 * 1024;

  /// The file name, unique within the item.
  final String name;

  /// Size in bytes.
  final int size;

  /// When it was last written.
  final DateTime? modified;

  Json toJson() => {'name': name, 'size': size, 'modified': modified?.toUtc().toIso8601String()};
}
