import 'dart:typed_data';

import 'package:pure_zstd/src/bit_reader.dart';
import 'package:pure_zstd/src/exception.dart';
import 'package:pure_zstd/src/fse.dart';
import 'package:test/test.dart';

/// `fseDecodeInterleaved` has no symbol count to stop on: it runs until the
/// bitstream is spent, so the only thing keeping it inside the caller's
/// buffer is its own room check. Both of its exhausted branches write a third
/// symbol in the same pass, so a check for two let `at` reach `outLimit`,
/// which is one past the end.
///
/// `HuffmanTable` calls it with a 256-byte buffer, so overrunning it indexes
/// `_weights[256]`. This is the same reproducer as the 53-byte frame in the
/// corpus, with the frame stripped away: the weight table description and the
/// bitstream the block carried, handed straight to the function.
void main() {
  group('fseDecodeInterleaved', () {
    // The two bytes are the whole FSE table description: accuracy log 5 and a
    // distribution that gives the stream below two symbols per state pair.
    final description = Uint8List.fromList([0x10, 0x3F]);

    // 33 bytes of 0xAA and then the end marker, which is the stream the
    // crafted block put after the description.
    final stream = Uint8List.fromList([...List.filled(33, 0xAA), 0x02]);

    test('refuses a stream longer than the caller has room for', () {
      final table = FseTable(6);
      expect(readFseTable(table, description, 0, description.length, 255), 2);

      final bits = ReverseBitReader()..reset(stream, 0, stream.length);
      final weights = Uint8List(256);

      expect(
        () => fseDecodeInterleaved(table, bits, weights, 0, weights.length),
        throwsA(isA<ZstdException>()),
      );
    });

    test('fills the buffer exactly when there is room for the last pass', () {
      final table = FseTable(6);
      readFseTable(table, description, 0, description.length, 255);

      // Same stream, a buffer with slack. The count it returns must be the
      // symbols it actually wrote, so the last pass cannot have been longer
      // than the room the check left.
      final bits = ReverseBitReader()..reset(stream, 0, stream.length);
      final room = Uint8List(1024);
      final written = fseDecodeInterleaved(table, bits, room, 0, room.length);
      expect(written, greaterThan(256));
      expect(written, lessThanOrEqualTo(room.length));
    });
  });
}
