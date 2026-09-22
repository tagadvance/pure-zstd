import 'dart:io';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';
import 'package:test/test.dart';

/// The committed container was written by `hgtz.py`, so it is a
/// real level-19 pyzstd frame rather than anything this package produced.
///
/// Every sample in it is `(northRow * 1000 + column) % 30000`, which makes the
/// expected bytes of each block computable without a reference decompressor.
void main() {
  group('a real .hgtz container', () {
    final bytes = File('test/fixtures/N51E000.hgtz').readAsBytesSync();
    final header = ByteData.sublistView(bytes);
    final rows = header.getUint16(6);
    final columns = header.getUint16(8);
    final block = header.getUint16(10);
    final blockColumns = (columns + block - 1) ~/ block;
    final blockRows = (rows + block - 1) ~/ block;

    test('has the shape its README documents', () {
      expect(rows, 1201);
      expect(columns, 121);
      expect(block, 256);
      expect(blockRows * blockColumns, 5);
    });

    test('decodes every block to the samples the generator wrote', () {
      final decoder = ZstdDecoder();
      for (var index = 0; index < blockRows * blockColumns; index++) {
        final entry = 12 + 8 * index;
        final offset = header.getUint32(entry);
        final length = header.getUint32(entry + 4);
        final blockRow = index ~/ blockColumns;
        final blockColumn = index % blockColumns;
        final top = blockRow * block;
        final left = blockColumn * block;
        final height = block < rows - top ? block : rows - top;
        final width = block < columns - left ? block : columns - left;

        final frame = Uint8List.sublistView(bytes, offset, offset + length);
        final out = decoder.decode(frame);

        expect(out.length, height * width * 2, reason: 'block $index size');
        final samples = ByteData.sublistView(out);
        for (var row = 0; row < height; row++) {
          for (var column = 0; column < width; column++) {
            // Row 0 of the container is the north edge, which is what the
            // generator counted from.
            final northRow = top + row;
            final expected = (northRow * 1000 + left + column) % 30000;
            expect(
              samples.getInt16((row * width + column) * 2),
              expected,
              reason: 'block $index at $row,$column',
            );
          }
        }
      }
    });
  });
}
