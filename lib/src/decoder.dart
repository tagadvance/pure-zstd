import 'dart:typed_data';

import 'bit_reader.dart';
import 'exception.dart';
import 'fse.dart';
import 'huffman.dart';
import 'tables.dart';
import 'xxhash.dart';

/// Decodes zstd frames, holding its entropy tables and scratch between calls
/// so that decoding a second frame allocates nothing but the output.
///
/// One instance is not safe to share between isolates, and a frame must be
/// decoded to completion before the next one starts.
class ZstdDecoder {
  ZstdDecoder({this.maxOutputSize = defaultMaxOutputSize});

  static const int magic = 0xFD2FB528;

  /// The largest output this decoder will allocate for one frame.
  ///
  /// `Frame_Content_Size` is up to a 64-bit number taken straight from the
  /// input and it used to size the output buffer unchecked, so a sixteen-byte
  /// frame could ask for four exbibytes. It is reachable by accident as well
  /// as by design: one bit flipped in a real tile's frame descriptor moves
  /// the content-size flag from 2 to 3, eight bytes of compressed data are
  /// read as the size, and the eighth lands on the sign bit. That is a
  /// `RangeError` for a negative length, or an `OutOfMemoryError` for a large
  /// positive one, and both are `Error` rather than `Exception`, so a caller
  /// writing `on ZstdException` does not catch either and the isolate dies.
  ///
  /// RFC 8878 section 3.1.1.1.2 lets a decoder refuse a frame that asks for
  /// more memory than it is willing to give, which is the job of the window
  /// descriptor this package skips. Allocating the output whole is why it can
  /// skip it, and this is the bound that replaces it.
  ///
  /// A caller that knows the exact size should pass [decode]'s `expectedSize`
  /// instead and get an exact check rather than a ceiling. The `.hgtz` reader
  /// knows it: a block is `height * width * 2`.
  static const int defaultMaxOutputSize = 64 * 1024 * 1024;

  /// The ceiling this instance enforces. See [defaultMaxOutputSize].
  final int maxOutputSize;

  /// The largest block a frame may contain, and so the most literals one
  /// block can hold.
  static const int maxBlockSize = 128 * 1024;

  final Xxh64 _hash = Xxh64();
  final ReverseBitReader _bits = ReverseBitReader();
  final HuffmanTable _huffman = HuffmanTable();
  final FseTable _literalLengths = FseTable(literalLengthMaxLog);
  final FseTable _matchLengths = FseTable(matchLengthMaxLog);
  final FseTable _offsets = FseTable(offsetCodeMaxLog);

  bool _literalLengthsReady = false;
  bool _matchLengthsReady = false;
  bool _offsetsReady = false;

  /// The three recent offsets. They live for the whole frame, so a later
  /// block can refer back to one a previous block established.
  int _repeat1 = 1;
  int _repeat2 = 4;
  int _repeat3 = 8;

  Uint8List _literals = Uint8List(maxBlockSize);

  /// Where the current block's literals live: either [_literals] or, for raw
  /// literals, the frame itself.
  Uint8List _literalSource = Uint8List(0);
  int _literalAt = 0;
  int _literalEnd = 0;

  /// Decodes one frame.
  ///
  /// [expectedSize] is only needed when the frame header omits its content
  /// size, which the containers this was written for never do.
  Uint8List decode(Uint8List src, {int? expectedSize}) {
    if (src.length < 6) {
      throw const ZstdException('too short to be a zstd frame');
    }
    if (src[0] | (src[1] << 8) | (src[2] << 16) | (src[3] << 24) != magic) {
      throw const ZstdException('not a zstd frame: bad magic');
    }

    final descriptor = src[4];
    var at = 5;
    final contentSizeFlag = descriptor >> 6;
    final singleSegment = (descriptor >> 5) & 1;
    if ((descriptor >> 3) & 1 != 0) {
      throw const ZstdException('frame header reserved bit set');
    }
    final checksum = (descriptor >> 2) & 1;
    final dictionaryFlag = descriptor & 3;

    if (singleSegment == 0) {
      at++; // Window_Descriptor. The output is allocated whole, so unused.
    }
    if (dictionaryFlag != 0) {
      throw const ZstdException('dictionaries are not supported');
    }

    final contentSizeBytes = switch (contentSizeFlag) {
      0 => singleSegment == 1 ? 1 : 0,
      1 => 2,
      2 => 4,
      _ => 8,
    };
    if (at + contentSizeBytes > src.length) {
      throw const ZstdException('truncated frame header');
    }
    int? contentSize;
    if (contentSizeBytes > 0) {
      var value = 0;
      for (var k = 0; k < contentSizeBytes; k++) {
        value |= src[at + k] << (8 * k);
      }
      // The two-byte form is biased, since a frame that small would use the
      // one-byte form.
      contentSize = contentSizeBytes == 2 ? value + 256 : value;
      at += contentSizeBytes;
    }

    final size = contentSize ?? expectedSize;
    if (size == null) {
      throw const ZstdException(
        'frame declares no content size and none was given',
      );
    }
    // Before the allocation, and before any of it is trusted.
    if (size < 0 || size > maxOutputSize) {
      throw ZstdException('frame declares $size bytes, over the maximum');
    }
    // When the caller knows the size, the frame agreeing with it is the
    // check. Left to the end, a frame declaring less decoded its own
    // content happily and a frame declaring more allocated whatever it
    // asked for first.
    if (contentSize != null && expectedSize != null && size != expectedSize) {
      throw ZstdException('frame declares $size bytes, not $expectedSize');
    }
    final out = Uint8List(size);

    _huffman.log = 0;
    _literalLengthsReady = false;
    _matchLengthsReady = false;
    _offsetsReady = false;
    _repeat1 = 1;
    _repeat2 = 4;
    _repeat3 = 8;

    // Only when the frame carries one. Hashing every frame would cost the
    // .hgtz reader throughput it has no use for, since pyzstd writes no
    // checksum and the container's own SHA-256 is verified on download.
    final hash = checksum == 1 ? (_hash..reset()) : null;

    var written = 0;
    while (true) {
      final blockStart = written;
      if (at + 3 > src.length) {
        throw const ZstdException('truncated block header');
      }
      final header = src[at] | (src[at + 1] << 8) | (src[at + 2] << 16);
      at += 3;
      final last = header & 1;
      final type = (header >> 1) & 3;
      final blockSize = header >> 3;
      // Every type, RLE included. Its Block_Size is its regenerated size and
      // the format bounds it like any other, and exempting it let a 97-byte
      // input return 44 MB that a caller cannot tell from a good tile.
      if (blockSize > maxBlockSize) {
        throw ZstdException('block of $blockSize bytes is over the maximum');
      }

      switch (type) {
        case 0:
          if (at + blockSize > src.length || written + blockSize > out.length) {
            throw const ZstdException('raw block does not fit');
          }
          out.setRange(written, written + blockSize, src, at);
          written += blockSize;
          at += blockSize;
        case 1:
          if (at >= src.length || written + blockSize > out.length) {
            throw const ZstdException('RLE block does not fit');
          }
          out.fillRange(written, written + blockSize, src[at]);
          written += blockSize;
          at += 1;
        case 2:
          if (at + blockSize > src.length) {
            throw const ZstdException('truncated compressed block');
          }
          written = _decodeBlock(src, at, at + blockSize, out, written);
          at += blockSize;
        default:
          throw const ZstdException('reserved block type');
      }

      hash?.update(out, blockStart, written);

      if (last == 1) {
        break;
      }
    }

    if (checksum == 1) {
      if (at + 4 > src.length) {
        throw const ZstdException('truncated content checksum');
      }
      // The low 32 bits of XXH64 over the whole output, little-endian.
      // Skipping it left the decoder with no integrity check at all: over
      // 600,000 mutations of real block data, a third decoded into wrong
      // bytes and raised nothing, because a damaged match or literal length
      // usually still produces *some* plausible output of the right size.
      final stored =
          src[at] |
          (src[at + 1] << 8) |
          (src[at + 2] << 16) |
          (src[at + 3] << 24);
      if (stored != hash!.digest32) {
        throw const ZstdException('the frame checksum does not match');
      }
      at += 4;
    }
    if (written != out.length) {
      throw ZstdException('frame decoded to $written bytes, not ${out.length}');
    }
    // Reading one frame is the whole API, so anything after it is input this
    // decoder does not understand. Nothing used to compare the cursor with
    // the length, so a second frame, a trailing skippable frame, and four
    // bytes of junk were all accepted and silently ignored: two frames
    // concatenated returned the first one's bytes and raised nothing.
    if (at != src.length) {
      throw ZstdException('${src.length - at} bytes after the frame');
    }

    return out;
  }

  /// Decodes one compressed block, returning the new output position.
  int _decodeBlock(
    Uint8List src,
    int start,
    int end,
    Uint8List out,
    int written,
  ) {
    var at = _decodeLiterals(src, start, end);
    if (at == end) {
      throw const ZstdException('block has no sequences section');
    }

    // Number_of_Sequences, one to three bytes.
    final first = src[at++];
    int sequences;
    if (first == 0) {
      sequences = 0;
    } else if (first < 128) {
      sequences = first;
    } else if (first < 255) {
      if (at >= end) {
        throw const ZstdException('truncated sequence count');
      }
      sequences = ((first - 128) << 8) + src[at++];
    } else {
      if (at + 2 > end) {
        throw const ZstdException('truncated sequence count');
      }
      sequences = src[at] + (src[at + 1] << 8) + 0x7F00;
      at += 2;
    }

    if (sequences == 0) {
      return _copyRemainingLiterals(out, written);
    }

    if (at >= end) {
      throw const ZstdException('truncated compression modes');
    }
    final modes = src[at++];
    if (modes & 3 != 0) {
      throw const ZstdException('sequence modes reserved bits set');
    }
    at = _readSequenceTable(
      _literalLengths,
      modes >> 6,
      literalLengthDefault,
      6,
      literalLengthMaxSymbol,
      src,
      at,
      end,
      _literalLengthsReady,
    );
    _literalLengthsReady = true;
    at = _readSequenceTable(
      _offsets,
      (modes >> 4) & 3,
      offsetCodeDefault,
      5,
      offsetCodeMaxSymbol,
      src,
      at,
      end,
      _offsetsReady,
    );
    _offsetsReady = true;
    at = _readSequenceTable(
      _matchLengths,
      (modes >> 2) & 3,
      matchLengthDefault,
      6,
      matchLengthMaxSymbol,
      src,
      at,
      end,
      _matchLengthsReady,
    );
    _matchLengthsReady = true;

    return _executeSequences(src, at, end, out, written, sequences);
  }

  int _readSequenceTable(
    FseTable table,
    int mode,
    List<int> predefined,
    int predefinedLog,
    int maxSymbol,
    Uint8List src,
    int at,
    int end,
    bool ready,
  ) {
    switch (mode) {
      case 0:
        buildPredefined(table, predefined, predefinedLog);
        return at;
      case 1:
        if (at >= end) {
          throw const ZstdException('truncated RLE sequence table');
        }
        if (src[at] > maxSymbol) {
          throw ZstdException('RLE sequence symbol ${src[at]} out of range');
        }
        table.setRle(src[at]);
        return at + 1;
      case 2:
        return at + readFseTable(table, src, at, end, maxSymbol);
      default:
        if (!ready) {
          throw const ZstdException('repeat mode with no previous table');
        }
        return at;
    }
  }

  /// Reads the literals section, leaving the literals addressable through
  /// [_literalSource]. Returns the offset just past the section.
  int _decodeLiterals(Uint8List src, int start, int end) {
    if (start >= end) {
      throw const ZstdException('empty compressed block');
    }
    var at = start;
    final header = src[at];
    final type = header & 3;
    final sizeFormat = (header >> 2) & 3;

    if (type < 2) {
      int regenerated;
      if (sizeFormat & 1 == 0) {
        regenerated = header >> 3;
        at += 1;
      } else if (sizeFormat == 1) {
        if (at + 2 > end) {
          throw const ZstdException('truncated literals header');
        }
        regenerated = (header >> 4) | (src[at + 1] << 4);
        at += 2;
      } else {
        if (at + 3 > end) {
          throw const ZstdException('truncated literals header');
        }
        regenerated = (header >> 4) | (src[at + 1] << 4) | (src[at + 2] << 12);
        at += 3;
      }
      if (regenerated > maxBlockSize) {
        throw ZstdException('$regenerated literals is over the maximum');
      }
      if (type == 0) {
        if (at + regenerated > end) {
          throw const ZstdException('truncated raw literals');
        }
        // No copy: the literals are already contiguous in the frame.
        _literalSource = src;
        _literalAt = at;
        _literalEnd = at + regenerated;
        return at + regenerated;
      }
      if (at >= end) {
        throw const ZstdException('truncated RLE literals');
      }
      _literals.fillRange(0, regenerated, src[at]);
      _literalSource = _literals;
      _literalAt = 0;
      _literalEnd = regenerated;
      return at + 1;
    }

    final int regenerated;
    final int compressed;
    final int streams;
    switch (sizeFormat) {
      case 0:
      case 1:
        if (at + 3 > end) {
          throw const ZstdException('truncated literals header');
        }
        final value = src[at] | (src[at + 1] << 8) | (src[at + 2] << 16);
        regenerated = (value >> 4) & 0x3FF;
        compressed = (value >> 14) & 0x3FF;
        streams = sizeFormat == 0 ? 1 : 4;
        at += 3;
      case 2:
        if (at + 4 > end) {
          throw const ZstdException('truncated literals header');
        }
        final value =
            src[at] |
            (src[at + 1] << 8) |
            (src[at + 2] << 16) |
            (src[at + 3] << 24);
        regenerated = (value >> 4) & 0x3FFF;
        compressed = (value >> 18) & 0x3FFF;
        streams = 4;
        at += 4;
      default:
        if (at + 5 > end) {
          throw const ZstdException('truncated literals header');
        }
        final value =
            src[at] |
            (src[at + 1] << 8) |
            (src[at + 2] << 16) |
            (src[at + 3] << 24) |
            (src[at + 4] << 32);
        regenerated = (value >> 4) & 0x3FFFF;
        compressed = (value >> 22) & 0x3FFFF;
        streams = 4;
        at += 5;
    }
    if (regenerated > maxBlockSize) {
      throw ZstdException('$regenerated literals is over the maximum');
    }
    if (at + compressed > end) {
      throw const ZstdException('truncated compressed literals');
    }
    if (_literals.length < regenerated) {
      _literals = Uint8List(regenerated);
    }

    var streamStart = at;
    final streamEnd = at + compressed;
    if (type == 2) {
      streamStart += _huffman.read(src, at, streamEnd, _bits);
    }

    if (streams == 1) {
      _huffman.decodeStream(
        _bits,
        src,
        streamStart,
        streamEnd,
        _literals,
        0,
        regenerated,
      );
    } else {
      if (streamStart + 6 > streamEnd) {
        throw const ZstdException('truncated literals jump table');
      }
      final one = src[streamStart] | (src[streamStart + 1] << 8);
      final two = src[streamStart + 2] | (src[streamStart + 3] << 8);
      final three = src[streamStart + 4] | (src[streamStart + 5] << 8);
      var from = streamStart + 6;
      final four = streamEnd - from - one - two - three;
      if (four < 0) {
        throw const ZstdException('literals jump table does not add up');
      }
      // The first three streams carry a quarter each, rounded up.
      final segment = (regenerated + 3) >> 2;
      final sizes = <int>[one, two, three, four];
      var outAt = 0;
      for (var i = 0; i < 4; i++) {
        final count = i == 3 ? regenerated - 3 * segment : segment;
        if (count < 0) {
          throw const ZstdException('literals do not split into four');
        }
        if (count > 0) {
          _huffman.decodeStream(
            _bits,
            src,
            from,
            from + sizes[i],
            _literals,
            outAt,
            count,
          );
        }
        from += sizes[i];
        outAt += count;
      }
    }

    _literalSource = _literals;
    _literalAt = 0;
    _literalEnd = regenerated;

    return streamEnd;
  }

  int _copyRemainingLiterals(Uint8List out, int written) {
    final count = _literalEnd - _literalAt;
    if (written + count > out.length) {
      throw const ZstdException('literals overflow the frame content size');
    }
    out.setRange(written, written + count, _literalSource, _literalAt);
    _literalAt = _literalEnd;

    return written + count;
  }

  int _executeSequences(
    Uint8List src,
    int start,
    int end,
    Uint8List out,
    int written,
    int sequences,
  ) {
    final bits = _bits;
    bits.reset(src, start, end);

    final llSymbol = _literalLengths.symbol;
    final llBits = _literalLengths.nbBits;
    final llNext = _literalLengths.newState;
    final mlSymbol = _matchLengths.symbol;
    final mlBits = _matchLengths.nbBits;
    final mlNext = _matchLengths.newState;
    final ofSymbol = _offsets.symbol;
    final ofBits = _offsets.nbBits;
    final ofNext = _offsets.newState;

    var llState = bits.read(_literalLengths.log);
    var ofState = bits.read(_offsets.log);
    var mlState = bits.read(_matchLengths.log);

    final literals = _literalSource;
    var literalAt = _literalAt;
    final literalEnd = _literalEnd;
    var at = written;

    var repeat1 = _repeat1;
    var repeat2 = _repeat2;
    var repeat3 = _repeat3;

    for (var n = 0; n < sequences; n++) {
      // Every table's symbols were bounded when it was built, so a code out
      // of range is impossible here and is not re-checked per sequence.
      final llCode = llSymbol[llState];
      final mlCode = mlSymbol[mlState];
      final ofCode = ofSymbol[ofState];

      // Additional bits come off the stream offset first, then match
      // length, then literals length.
      bits.fill();
      final offsetValue = (1 << ofCode) + bits.read(ofCode);
      final matchLength =
          matchLengthBaseline[mlCode] + bits.read(matchLengthExtra[mlCode]);
      final literalLength =
          literalLengthBaseline[llCode] + bits.read(literalLengthExtra[llCode]);

      if (n + 1 < sequences) {
        // The three updates together need at most 26 bits, which one fill
        // covers, so they peek rather than each testing for a refill.
        bits.fill();
        final llTake = llBits[llState];
        llState = llNext[llState] + bits.peek(llTake);
        bits.skip(llTake);
        final mlTake = mlBits[mlState];
        mlState = mlNext[mlState] + bits.peek(mlTake);
        bits.skip(mlTake);
        final ofTake = ofBits[ofState];
        ofState = ofNext[ofState] + bits.peek(ofTake);
        bits.skip(ofTake);
      }

      int offset;
      if (offsetValue > 3) {
        offset = offsetValue - 3;
        repeat3 = repeat2;
        repeat2 = repeat1;
        repeat1 = offset;
      } else {
        // One to three is a reference to a recent offset, and a sequence
        // with no literals shifts which one it means.
        final which = offsetValue - 1 + (literalLength == 0 ? 1 : 0);
        if (which == 0) {
          offset = repeat1;
        } else {
          offset = which == 3 ? repeat1 - 1 : (which == 1 ? repeat2 : repeat3);
          if (offset == 0) {
            throw const ZstdException('repeated offset of zero');
          }
          if (which != 1) {
            repeat3 = repeat2;
          }
          repeat2 = repeat1;
          repeat1 = offset;
        }
      }

      if (literalAt + literalLength > literalEnd) {
        throw const ZstdException('sequence wants more literals than exist');
      }
      if (at + literalLength + matchLength > out.length) {
        throw const ZstdException('sequences overflow the content size');
      }
      final from = at + literalLength - offset;
      if (from < 0) {
        throw const ZstdException('match reaches before the output');
      }

      if (literalLength > 0) {
        if (literalLength < 16) {
          for (var i = 0; i < literalLength; i++) {
            out[at++] = literals[literalAt++];
          }
        } else {
          out.setRange(at, at + literalLength, literals, literalAt);
          at += literalLength;
          literalAt += literalLength;
        }
      }

      if (matchLength < 16 || offset < matchLength) {
        // A short or overlapping match is quicker byte by byte than through
        // a range copy, and the median match here is nine bytes.
        var source = from;
        for (var i = 0; i < matchLength; i++) {
          out[at++] = out[source++];
        }
      } else {
        out.setRange(at, at + matchLength, out, from);
        at += matchLength;
      }
    }

    if (bits.exhausted) {
      throw const ZstdException('sequence stream ran past its end');
    }

    _literalAt = literalAt;
    _repeat1 = repeat1;
    _repeat2 = repeat2;
    _repeat3 = repeat3;

    return _copyRemainingLiterals(out, at);
  }
}

/// Decodes one zstd frame into a new list.
///
/// Allocates a decoder per call. Decoding many frames, which is what reading
/// a tile does, should hold a [ZstdDecoder] instead.
Uint8List zstdDecode(Uint8List src, {int? expectedSize}) =>
    ZstdDecoder().decode(src, expectedSize: expectedSize);
