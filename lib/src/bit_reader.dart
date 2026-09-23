import 'dart:typed_data';

import 'exception.dart';

/// Reads a zstd entropy bitstream, which runs backwards.
///
/// Every FSE and Huffman stream in a zstd frame is written from its end: the
/// last byte holds the first bits, and within a byte the most significant bit
/// comes first. Read as a little-endian integer the whole stream is one big
/// number consumed from the top down, which is what this does.
///
/// The final byte carries a set bit marking where the data stops; the zeroes
/// above it are padding and the marker itself is not data.
class ReverseBitReader {
  ReverseBitReader();

  Uint8List _bytes = Uint8List(0);

  /// A view over [_bytes], so a refill can take four bytes at a time. Kept
  /// between resets, since every stream in one block shares a buffer.
  ByteData _view = ByteData(0);

  /// Index of the first byte of the stream. Reading stops when it is reached.
  int _start = 0;

  /// Index of the next byte to pull into [_acc], counting down to [_start].
  int _next = 0;

  /// The unread bits, in the low [_available] bits, next bit at the top.
  int _acc = 0;
  int _available = 0;

  /// Zero bits shifted in past the front of the stream. They are only ever
  /// at the bottom of [_acc], so any unread count below this means the
  /// stream was over-read.
  int _padding = 0;

  void reset(Uint8List bytes, int start, int end) {
    if (end <= start) {
      throw const ZstdException('empty entropy stream');
    }
    final last = bytes[end - 1];
    if (last == 0) {
      throw const ZstdException('entropy stream has no end marker');
    }
    if (!identical(bytes, _bytes)) {
      _bytes = bytes;
      _view = ByteData.sublistView(bytes);
    }
    _start = start;
    _next = end - 1;
    _acc = last;
    // bitLength - 1 is the marker's position; the data is everything below.
    _available = last.bitLength - 1;
    _padding = 0;
  }

  /// True once more bits have been taken than the stream held.
  bool get exhausted => _available < _padding;

  /// Tops [_acc] up to at least 49 bits, so a [peek] of up to 32 is safe and
  /// several small reads can follow one call.
  void fill() {
    if (_available > 48) {
      return;
    }
    var acc = _acc & ((1 << _available) - 1);
    var available = _available;
    var next = _next;
    // Four bytes at a time while there is room for them. The stream is one
    // little-endian number read from the top down, so a little-endian word
    // lands the four bytes in the order the byte-at-a-time loop would.
    while (available <= 24 && next - 4 >= _start) {
      next -= 4;
      acc = (acc << 32) | _view.getUint32(next, Endian.little);
      available += 32;
    }
    while (available <= 48) {
      if (next > _start) {
        next--;
        acc = (acc << 8) | _bytes[next];
      } else {
        acc <<= 8;
        _padding += 8;
      }
      available += 8;
    }
    _acc = acc;
    _available = available;
    _next = next;
  }

  /// The next [count] bits without consuming them. Caller has called [fill].
  int peek(int count) => (_acc >> (_available - count)) & ((1 << count) - 1);

  void skip(int count) {
    _available -= count;
  }

  /// Reads [count] bits, refilling as needed. `count == 0` yields 0.
  int read(int count) {
    if (_available < count) {
      fill();
    }
    _available -= count;
    return (_acc >> _available) & ((1 << count) - 1);
  }
}

/// Reads the forward, least-significant-bit-first bitstream that an FSE table
/// description uses. Table descriptions are tiny and read once per block, so
/// this favours being obviously correct over being quick.
class ForwardBitReader {
  ForwardBitReader(this._bytes, this._end, int startByte)
    : _position = startByte * 8;

  final Uint8List _bytes;
  final int _end;
  int _position;

  /// The next 32 bits, unconsumed. Reads past the end come back as zeroes.
  int peek32() {
    final index = _position >> 3;
    var value = 0;
    for (var k = 0; k < 5; k++) {
      final at = index + k;
      if (at < _end) {
        value |= _bytes[at] << (8 * k);
      }
    }
    return value >> (_position & 7);
  }

  void skip(int count) {
    _position += count;
  }

  /// The number of bytes consumed, counting a partial byte as whole.
  int bytesUsed(int startByte) => ((_position + 7) >> 3) - startByte;
}
