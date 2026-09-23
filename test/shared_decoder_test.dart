import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';
import 'package:test/test.dart';

import 'corpus.dart';

/// One `ZstdDecoder` over a mixed list of frames, forward and then reversed.
///
/// A decoder holds its Huffman table, its three FSE tables, the three "table
/// is ready to repeat" flags and the three recent offsets between calls, and
/// every one of those is per frame. A frame that leaves a table behind is
/// invisible while every frame in the list looks alike, which is exactly what
/// the real `.hgtz` corpus is. Reversing the order moves each frame to a
/// different predecessor, so a leak shows up as a difference between the two
/// passes or against what pyzstd gave.
void main() {
  final mixed = loadCorpus()
      .where((entry) => entry.legal && entry.trailing == null)
      .toList();

  test('decodes ${mixed.length} mixed frames the same in either order', () {
    expect(mixed.length, greaterThan(5), reason: 'the list must be mixed');

    final decoder = ZstdDecoder();
    final forward = <String, Uint8List>{
      for (final entry in mixed)
        entry.name: decoder.decode(
          entry.frame,
          expectedSize: entry.expectedSize,
        ),
    };

    final backward = <String, Uint8List>{};
    for (final entry in mixed.reversed) {
      backward[entry.name] = decoder.decode(
        entry.frame,
        expectedSize: entry.expectedSize,
      );
    }

    for (final entry in mixed) {
      expect(
        forward[entry.name],
        orderedEquals(entry.plain),
        reason: '${entry.name} decoded wrongly in order',
      );
      expect(
        backward[entry.name],
        orderedEquals(entry.plain),
        reason: '${entry.name} decoded wrongly reversed',
      );
    }
  });

  test('a refused frame does not poison the next one', () {
    final decoder = ZstdDecoder();
    final bad = loadCorpus().where((entry) => !entry.legal).toList();
    for (final good in mixed) {
      for (final entry in bad) {
        try {
          decoder.decode(entry.frame);
        } on ZstdException {
          // The point of the case. Some are open defects and decode fine.
        }
      }
      expect(
        decoder.decode(good.frame, expectedSize: good.expectedSize),
        orderedEquals(good.plain),
        reason: '${good.name} after a run of malformed frames',
      );
    }
  });
}
