typedef Json = Map<String, Object?>;

/// Thrown when a payload does not have the expected shape.
final class MalformedPayloadException implements Exception {
  const MalformedPayloadException(this.message);

  final String message;

  @override
  String toString() => 'Malformed payload: $message';
}

/// Typed access to decoded JSON objects.
extension JsonRead on Json {
  T _typed<T>(String key) {
    final value = this[key];
    if (value is T) return value;
    throw MalformedPayloadException('"$key" should be $T, got ${value.runtimeType}.');
  }

  String string(String key) => _typed<String>(key);

  String? optionalString(String key) => _typed<String?>(key);

  bool boolean(String key, {bool fallback = false}) => _typed<bool?>(key) ?? fallback;

  int integer(String key, {int fallback = 0}) => _typed<int?>(key) ?? fallback;

  Json object(String key) => _typed<Map<String, Object?>>(key);

  Json? optionalObject(String key) => _typed<Map<String, Object?>?>(key);

  List<Json> objects(String key) => [for (final value in _typed<List<Object?>?>(key) ?? const []) asJson(value)];

  List<String> strings(String key) => [for (final value in _typed<List<Object?>?>(key) ?? const []) '$value'];
}

Json asJson(Object? value) =>
    value is Map<String, Object?> ? value : throw MalformedPayloadException('Expected an object, got $value.');
