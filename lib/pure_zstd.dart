/// A pure Dart zstd decompressor.
///
/// Decompression only, and only the subset of RFC 8878 that the elevation
/// containers this was written for use. See the README for what is left out.
library;

export 'src/decoder.dart' show ZstdDecoder, zstdDecode;
export 'src/exception.dart' show ZstdException;
