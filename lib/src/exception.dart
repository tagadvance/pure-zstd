/// Thrown when a frame is malformed, or uses a feature this decoder omits.
///
/// Every refusal from this package is one of these, so `on ZstdException` is
/// enough to survive untrusted input.
class ZstdException implements Exception {
  /// Creates an exception carrying [message].
  const ZstdException(this.message);

  /// What was wrong with the frame, for a log rather than for matching on.
  final String message;

  @override
  String toString() => 'ZstdException: $message';
}
