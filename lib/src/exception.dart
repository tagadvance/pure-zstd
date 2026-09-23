/// Thrown when a frame is malformed, or uses a feature this decoder omits.
class ZstdException implements Exception {
  const ZstdException(this.message);

  final String message;

  @override
  String toString() => 'ZstdException: $message';
}
