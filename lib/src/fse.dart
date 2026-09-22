import 'dart:typed_data';

import 'bit_reader.dart';
import 'exception.dart';

/// An FSE decoding table: one entry per state, giving the symbol that state
/// emits, how many bits to read next, and the base the read is added to.
///
/// The three arrays are parallel and sized for the largest accuracy log the
/// format allows, so a table is built in place and never reallocated.
class FseTable {
  FseTable(this.maxLog)
    : symbol = Uint8List(1 << maxLog),
      nbBits = Uint8List(1 << maxLog),
      newState = Uint16List(1 << maxLog),
      _spread = Uint8List(1 << maxLog);

  final int maxLog;

  final Uint8List symbol;
  final Uint8List nbBits;
  final Uint16List newState;

  /// Accuracy log. Zero for an RLE table, which has a single state.
  int log = 0;

  /// The normalised distribution this table was last built from. Written by
  /// [readFseTable] and [buildPredefined], read by [build].
  final Int16List distribution = Int16List(256);

  final Uint8List _spread;
  final Int32List _next = Int32List(256);

  /// Makes this a table with one state emitting [value] and reading no bits.
  void setRle(int value) {
    log = 0;
    symbol[0] = value;
    nbBits[0] = 0;
    newState[0] = 0;
  }

  /// Builds the table from [distribution], where a count of -1 is the "less
  /// than one in the table" symbol the format reserves.
  void build(int maxSymbol, int accuracyLog) {
    if (accuracyLog > maxLog) {
      throw ZstdException('FSE accuracy log $accuracyLog above $maxLog');
    }
    final size = 1 << accuracyLog;
    log = accuracyLog;

    // Low-probability symbols go at the top of the table, working down, and
    // then count as one when the states are numbered.
    var highThreshold = size - 1;
    for (var s = 0; s <= maxSymbol; s++) {
      final count = distribution[s];
      if (count == -1) {
        _spread[highThreshold--] = s;
        _next[s] = 1;
      } else {
        _next[s] = count;
      }
    }

    // The step is coprime with the table size, so walking it visits every
    // slot exactly once. Skipping the low-probability slots at the top is
    // what keeps those symbols where they were just put.
    final mask = size - 1;
    final step = (size >> 1) + (size >> 3) + 3;
    var position = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      final count = distribution[s];
      for (var i = 0; i < count; i++) {
        _spread[position] = s;
        position = (position + step) & mask;
        while (position > highThreshold) {
          position = (position + step) & mask;
        }
      }
    }
    if (position != 0) {
      throw const ZstdException('FSE distribution does not fill its table');
    }

    for (var state = 0; state < size; state++) {
      final s = _spread[state];
      final nth = _next[s]++;
      final bits = accuracyLog - (nth.bitLength - 1);
      symbol[state] = s;
      nbBits[state] = bits;
      newState[state] = (nth << bits) - size;
    }
  }
}

/// Reads an FSE table description into [table.distribution] and builds it.
///
/// Returns the number of bytes the description occupied. The description is a
/// forward, least-significant-bit-first bitstream: an accuracy log, then one
/// value per symbol coded in as few bits as the remaining probability mass
/// allows, with a repeat flag after any zero.
int readFseTable(
  FseTable table,
  Uint8List src,
  int start,
  int end,
  int maxSymbol,
) {
  final bits = ForwardBitReader(src, end, start);
  final counts = table.distribution;
  for (var s = 0; s <= maxSymbol; s++) {
    counts[s] = 0;
  }

  final accuracyLog = (bits.peek32() & 0xF) + 5;
  bits.skip(4);
  if (accuracyLog > table.maxLog) {
    throw ZstdException('FSE accuracy log $accuracyLog above ${table.maxLog}');
  }

  var remaining = (1 << accuracyLog) + 1;
  var threshold = 1 << accuracyLog;
  var nbBits = accuracyLog + 1;
  var symbol = 0;
  var previousZero = false;

  while (remaining > 1 && symbol <= maxSymbol) {
    if (previousZero) {
      var repeat = 0;
      while (true) {
        final flag = bits.peek32() & 3;
        bits.skip(2);
        repeat += flag;
        if (flag != 3) {
          break;
        }
      }
      while (repeat-- > 0) {
        if (symbol > maxSymbol) {
          throw const ZstdException('FSE zero run past the last symbol');
        }
        counts[symbol++] = 0;
      }
      previousZero = false;
      continue;
    }

    final value = bits.peek32();
    final small = (2 * threshold - 1) - remaining;
    int count;
    if ((value & (threshold - 1)) < small) {
      count = value & (threshold - 1);
      bits.skip(nbBits - 1);
    } else {
      count = value & (2 * threshold - 1);
      if (count >= threshold) {
        count -= small;
      }
      bits.skip(nbBits);
    }

    count -= 1;
    remaining -= count < 0 ? -count : count;
    counts[symbol++] = count;
    previousZero = count == 0;
    while (remaining < threshold) {
      nbBits--;
      threshold >>= 1;
    }
  }
  if (remaining != 1) {
    throw const ZstdException('FSE distribution is short');
  }

  table.build(symbol - 1, accuracyLog);

  return bits.bytesUsed(start);
}

/// Builds [table] from one of the format's fixed distributions.
void buildPredefined(FseTable table, List<int> values, int accuracyLog) {
  final counts = table.distribution;
  for (var s = 0; s < values.length; s++) {
    counts[s] = values[s];
  }
  table.build(values.length - 1, accuracyLog);
}

/// Decodes a whole FSE bitstream with the two interleaved states the format
/// uses, appending symbols to [out] from [outStart] and returning the count.
///
/// The symbol count is not recorded anywhere, so decoding runs until the
/// stream is spent. This is how the Huffman weights are coded.
int fseDecodeInterleaved(
  FseTable table,
  ReverseBitReader bits,
  Uint8List out,
  int outStart,
  int outLimit,
) {
  final symbol = table.symbol;
  final nbBits = table.nbBits;
  final newState = table.newState;
  final log = table.log;

  var state1 = bits.read(log);
  var state2 = bits.read(log);
  var at = outStart;

  while (true) {
    if (at + 2 > outLimit) {
      throw const ZstdException('FSE stream longer than its output allows');
    }
    out[at++] = symbol[state1];
    bits.fill();
    state1 = newState[state1] + bits.read(nbBits[state1]);
    if (bits.exhausted) {
      out[at++] = symbol[state2];
      break;
    }
    out[at++] = symbol[state2];
    bits.fill();
    state2 = newState[state2] + bits.read(nbBits[state2]);
    if (bits.exhausted) {
      out[at++] = symbol[state1];
      break;
    }
  }

  return at - outStart;
}
