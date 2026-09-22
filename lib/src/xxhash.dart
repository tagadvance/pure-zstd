/// XXH64, the hash zstd uses for `Content_Checksum`.
///
/// RFC 8878 section 3.1.1 stores the low 32 bits of the XXH64 of the whole
/// decompressed frame content, seeded with zero, little-endian, after the last
/// block. [Xxh64.digest32] is that value.
///
/// The algorithm is defined on unsigned 64-bit words that wrap. Dart's `int`
/// on the VM and on AOT is a 64-bit two's complement integer whose `+`, `-`,
/// `*` and `<<` wrap on overflow, and `>>>` shifts the raw bits in, so every
/// operation here is exact with no masking. None of that holds under dart2js,
/// where `int` is a double: the multiplies, the rotates and the wrapping adds
/// would all be wrong. Like the rest of this package, it targets native only.
library;

import 'dart:typed_data';

// The five primes, written as they appear in the reference implementation.
// Dart reads a hex literal above 2^63 as its two's complement, so _prime1,
// _prime2 and _prime4 are negative here. The bits are what matter.
const int _prime1 = 0x9E3779B185EBCA87;
const int _prime2 = 0xC2B2AE3D27D4EB4F;
const int _prime3 = 0x165667B19E3779F9;
const int _prime4 = 0x85EBCA77C2B2AE63;
const int _prime5 = 0x27D4EB2F165667C5;

/// Hashes [data] in one pass. Equivalent to `(Xxh64()..update(data)).digest`.
int xxh64(Uint8List data, {int seed = 0}) =>
    (Xxh64(seed: seed)..update(data)).digest;

/// XXH64 over as many chunks as the caller has.
///
/// A multi-block frame can feed each block to [update] as it is written,
/// rather than hashing the output again once it is whole. Reading [digest]
/// does not end the hash; more may be fed in afterwards.
class Xxh64 {
  Xxh64({int seed = 0}) : _seed = seed {
    reset();
  }

  final int _seed;

  /// Whole 32-byte stripes are consumed straight from the caller's bytes.
  /// This holds only the remainder between calls.
  final Uint8List _tail = Uint8List(32);
  late final ByteData _tailView = ByteData.sublistView(_tail);

  int _tailLength = 0;
  int _length = 0;

  int _v1 = 0;
  int _v2 = 0;
  int _v3 = 0;
  int _v4 = 0;

  /// Discards everything fed in so far, back to the seed given to the
  /// constructor.
  void reset() {
    _v1 = _seed + _prime1 + _prime2;
    _v2 = _seed + _prime2;
    _v3 = _seed;
    _v4 = _seed - _prime1;
    _tailLength = 0;
    _length = 0;
  }

  /// Feeds `data[start..end)`, defaulting to all of [data].
  ///
  /// The range form is so a decoder can hand over the part of an output buffer
  /// it just filled without taking a view of it.
  void update(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    var at = start;
    _length += stop - at;

    if (_tailLength > 0) {
      final take = stop - at < 32 - _tailLength ? stop - at : 32 - _tailLength;
      _tail.setRange(_tailLength, _tailLength + take, data, at);
      _tailLength += take;
      at += take;
      if (_tailLength < 32) {
        return;
      }
      _stripe(_tailView, 0);
      _tailLength = 0;
    }

    final view = ByteData.sublistView(data);
    while (at + 32 <= stop) {
      _stripe(view, at);
      at += 32;
    }

    if (at < stop) {
      _tail.setRange(0, stop - at, data, at);
      _tailLength = stop - at;
    }
  }

  /// The 64-bit hash of everything fed in so far.
  int get digest {
    // Under 32 bytes the accumulators were never touched, so the hash starts
    // from the seed instead of from their merge. _v3 still holds the seed.
    var h = _length >= 32
        ? _merge(
            _merge(
              _merge(
                _merge(
                  _rotl(_v1, 1) +
                      _rotl(_v2, 7) +
                      _rotl(_v3, 12) +
                      _rotl(_v4, 18),
                  _v1,
                ),
                _v2,
              ),
              _v3,
            ),
            _v4,
          )
        : _v3 + _prime5;
    h += _length;

    // The remainder is consumed eight bytes at a time, then four, then one.
    var at = 0;
    while (at + 8 <= _tailLength) {
      h ^= _round(0, _tailView.getInt64(at, Endian.little));
      h = _rotl(h, 27) * _prime1 + _prime4;
      at += 8;
    }
    if (at + 4 <= _tailLength) {
      h ^= _tailView.getUint32(at, Endian.little) * _prime1;
      h = _rotl(h, 23) * _prime2 + _prime3;
      at += 4;
    }
    while (at < _tailLength) {
      h ^= _tail[at] * _prime5;
      h = _rotl(h, 11) * _prime1;
      at++;
    }

    h ^= h >>> 33;
    h *= _prime2;
    h ^= h >>> 29;
    h *= _prime3;
    h ^= h >>> 32;
    return h;
  }

  /// The low 32 bits of [digest]: the value zstd stores as
  /// `Content_Checksum`.
  int get digest32 => digest & 0xFFFFFFFF;

  void _stripe(ByteData view, int at) {
    _v1 = _round(_v1, view.getInt64(at, Endian.little));
    _v2 = _round(_v2, view.getInt64(at + 8, Endian.little));
    _v3 = _round(_v3, view.getInt64(at + 16, Endian.little));
    _v4 = _round(_v4, view.getInt64(at + 24, Endian.little));
  }

  static int _round(int accumulator, int input) {
    final v = accumulator + input * _prime2;
    return _rotl(v, 31) * _prime1;
  }

  static int _merge(int h, int accumulator) =>
      (h ^ _round(0, accumulator)) * _prime1 + _prime4;

  static int _rotl(int v, int bits) => (v << bits) | (v >>> (64 - bits));
}
