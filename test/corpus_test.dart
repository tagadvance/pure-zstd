import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';
import 'package:test/test.dart';

import 'corpus.dart';

/// The committed corpus, which exists because `hgtz_block_test.dart` decodes
/// one container from one producer at one level and so proves the sequence
/// loop and Huffman literals on level-19 terrain and nothing else.
///
/// The frames here reach the parts of RFC 8878 that 16,490 real `.hgtz`
/// blocks never touch: raw blocks, RLE blocks, RLE literals, a frame with no
/// content size, a frame with a checksum, the eight-byte content size, and
/// the direct-nibble Huffman weight form.
///
/// Nothing below asserts what this decoder happens to do. A legal frame is
/// compared against what pyzstd decompressed it to; a refused frame is one
/// pyzstd also refuses. `tool/make_corpus.py` records both, along with the
/// exact command behind each frame, in `test/fixtures/corpus/manifest.json`.
void main() {
  final corpus = loadCorpus();

  group('a legal frame decodes to the bytes pyzstd gives', () {
    for (final entry in corpus.where(
      (entry) => entry.legal && entry.trailing == null,
    )) {
      test('${entry.name}: ${entry.command}', () {
        final out = ZstdDecoder().decode(
          entry.frame,
          expectedSize: entry.expectedSize,
        );
        expect(out.length, entry.size);
        expect(out, orderedEquals(entry.plain));
      });
    }
  });

  group('a malformed frame is refused, never crashed on', () {
    for (final entry in corpus.where((entry) => !entry.legal)) {
      // A `ZstdException` and nothing else. `RangeError`, `OutOfMemoryError`
      // and `IndexError` are all `Error` rather than `Exception`, so a caller
      // catching `ZstdException` does not catch them and the isolate dies.
      test('${entry.name}: ${entry.why}', () {
        expect(
          () => ZstdDecoder().decode(entry.frame),
          throwsA(isA<ZstdException>()),
        );
      });
    }
  });

  group('two frames in one buffer', () {
    final entry = corpus.singleWhere((entry) => entry.name == 'twoframes');
    final first = 5000;

    test('${entry.command}: decodes to both or refuses, never to the first '
        'alone', () {
      Uint8List? out;
      try {
        out = ZstdDecoder().decode(entry.frame);
      } on ZstdException {
        return; // Refusing is the other acceptable answer.
      }
      expect(
        out.length,
        isNot(first),
        reason: 'returned the first frame and stopped, raising nothing',
      );
      expect(out, orderedEquals(entry.plain));
    });
  });

  group('a frame declaring no content size', () {
    final entry = corpus.singleWhere((entry) => entry.name == 'nofcs_windowed');
    final size = entry.expectedSize!;

    test('decodes when given the size it really has', () {
      final out = ZstdDecoder().decode(entry.frame, expectedSize: size);
      expect(out, orderedEquals(entry.plain));
    });

    for (final wrong in <int>[size - 1, size + 1, 0]) {
      test('is refused when given $wrong instead of $size', () {
        expect(
          () => ZstdDecoder().decode(entry.frame, expectedSize: wrong),
          throwsA(isA<ZstdException>()),
        );
      });
    }
  });
}
