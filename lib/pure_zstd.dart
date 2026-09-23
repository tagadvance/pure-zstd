/// A pure Dart zstd decompressor.
///
/// Decompression only, one RFC 8878 frame per call, on native platforms. It
/// refuses dictionaries and skippable frames; see the README for the rest.
library;

export 'src/decoder.dart' show ZstdDecoder, zstdDecode;
export 'src/exception.dart' show ZstdException;
