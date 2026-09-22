import 'dart:typed_data';

import 'bit_reader.dart';
import 'exception.dart';
import 'fse.dart';

/// The Huffman table for a block's literals, flattened so that decoding one
/// literal is a peek of [log] bits and one array index.
///
/// Weights, not code lengths, are what the format stores: a symbol of weight
/// `w` occupies `1 << (w - 1)` of the table's slots, and the last symbol's
/// weight is left out and recovered from the slack.
class HuffmanTable {
  /// The largest table log the format allows for literals.
  static const int maxLog = 12;

  static const int _maxSymbols = 256;

  /// One entry per table slot: the symbol in the low byte, the code length
  /// in the next. One load per literal rather than two.
  final Uint16List entries = Uint16List(1 << maxLog);

  /// Bits to peek per literal. Zero until a table has been read.
  int log = 0;

  final Uint8List _weights = Uint8List(_maxSymbols);
  final Int32List _rankCount = Int32List(maxLog + 2);
  final Int32List _rankStart = Int32List(maxLog + 2);

  /// The FSE table the weights are coded with, when they are coded at all.
  final FseTable _weightTable = FseTable(6);

  /// Reads a Huffman tree description starting at [start], returning the
  /// number of bytes it occupied.
  int read(Uint8List src, int start, int end, ReverseBitReader bitReader) {
    if (start >= end) {
      throw const ZstdException('literals section has no tree');
    }
    final header = src[start];
    int nbWeights;
    int used;
    if (header >= 128) {
      // Directly encoded: one nibble per weight, high nibble first.
      nbWeights = header - 127;
      final packed = (nbWeights + 1) >> 1;
      if (start + 1 + packed > end) {
        throw const ZstdException('truncated Huffman weights');
      }
      for (var i = 0; i < nbWeights; i += 2) {
        final byte = src[start + 1 + (i >> 1)];
        _weights[i] = byte >> 4;
        if (i + 1 < nbWeights) {
          _weights[i + 1] = byte & 0xF;
        }
      }
      used = 1 + packed;
    } else {
      final size = header;
      if (start + 1 + size > end) {
        throw const ZstdException('truncated Huffman weight stream');
      }
      final read = readFseTable(
        _weightTable,
        src,
        start + 1,
        start + 1 + size,
        255,
      );
      bitReader.reset(src, start + 1 + read, start + 1 + size);
      nbWeights = fseDecodeInterleaved(
        _weightTable,
        bitReader,
        _weights,
        0,
        _maxSymbols,
      );
      used = 1 + size;
    }

    _buildFromWeights(nbWeights);

    return used;
  }

  void _buildFromWeights(int nbWeights) {
    if (nbWeights < 1 || nbWeights >= _maxSymbols) {
      throw ZstdException('Huffman table with $nbWeights weights');
    }
    var total = 0;
    for (var i = 0; i < nbWeights; i++) {
      final weight = _weights[i];
      if (weight > maxLog) {
        throw ZstdException('Huffman weight $weight out of range');
      }
      if (weight > 0) {
        total += 1 << (weight - 1);
      }
    }
    if (total == 0) {
      throw const ZstdException('Huffman table with no used symbol');
    }
    final tableLog = total.bitLength;
    if (tableLog > maxLog) {
      throw ZstdException('Huffman table log $tableLog above $maxLog');
    }
    final size = 1 << tableLog;
    final rest = size - total;
    if (rest & (rest - 1) != 0) {
      throw const ZstdException('Huffman weights do not complete a tree');
    }
    // The weight left out of the description is whatever fills the slack.
    _weights[nbWeights] = rest.bitLength;
    final nbSymbols = nbWeights + 1;
    log = tableLog;

    for (var n = 0; n < _rankCount.length; n++) {
      _rankCount[n] = 0;
    }
    for (var s = 0; s < nbSymbols; s++) {
      final weight = _weights[s];
      if (weight > 0) {
        _rankCount[tableLog + 1 - weight]++;
      }
    }
    // Codes are handed out from the lowest weight up, so the longest codes
    // take the lowest table indices and the shortest take the highest.
    var start = 0;
    for (var n = tableLog; n >= 1; n--) {
      _rankStart[n] = start;
      start += _rankCount[n] << (tableLog - n);
    }
    if (start != size) {
      throw const ZstdException('Huffman ranks do not fill the table');
    }

    // Within one code length, symbols keep their natural order.
    for (var s = 0; s < nbSymbols; s++) {
      final weight = _weights[s];
      if (weight == 0) {
        continue;
      }
      final length = tableLog + 1 - weight;
      final span = 1 << (weight - 1);
      var at = _rankStart[length];
      _rankStart[length] = at + span;
      final entry = s | (length << 8);
      for (var i = 0; i < span; i++) {
        entries[at++] = entry;
      }
    }
  }

  /// Decodes [count] literals from the reverse bitstream in [src] between
  /// [start] and [end] into [out] at [outStart].
  void decodeStream(
    ReverseBitReader reader,
    Uint8List src,
    int start,
    int end,
    Uint8List out,
    int outStart,
    int count,
  ) {
    if (log == 0) {
      throw const ZstdException('literals coded with no Huffman table');
    }
    reader.reset(src, start, end);
    final table = entries;
    final peekBits = log;
    var at = outStart;
    final stop = outStart + count;
    // One fill leaves at least 49 bits, which covers four literals at the
    // format's twelve-bit maximum, so the inner steps are a peek and an
    // index with nothing between them.
    final groups = stop - 4;
    while (at <= groups) {
      reader.fill();
      var entry = table[reader.peek(peekBits)];
      out[at++] = entry & 0xFF;
      reader.skip(entry >> 8);
      entry = table[reader.peek(peekBits)];
      out[at++] = entry & 0xFF;
      reader.skip(entry >> 8);
      entry = table[reader.peek(peekBits)];
      out[at++] = entry & 0xFF;
      reader.skip(entry >> 8);
      entry = table[reader.peek(peekBits)];
      out[at++] = entry & 0xFF;
      reader.skip(entry >> 8);
    }
    while (at < stop) {
      reader.fill();
      final entry = table[reader.peek(peekBits)];
      out[at++] = entry & 0xFF;
      reader.skip(entry >> 8);
    }
    if (reader.exhausted) {
      throw const ZstdException('Huffman stream ran past its end');
    }
  }
}
