import 'dart:io';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';

/// Times decoding real `.hgtz` blocks.
///
///     dart run benchmark/bench.dart [path to a .hgtz]
///     dart compile exe benchmark/bench.dart -o /tmp/bench && /tmp/bench
///
/// Reports the cost of one 256 by 256 block, which is 131,072 bytes out, and
/// the cost of the 113 blocks a 360 degree skyline sweep touches. The frames
/// are read into memory first, so nothing but decoding is timed. The output
/// buffer is allocated per call, as the API allocates it, so the figure
/// includes that allocation and the garbage it makes.
const int sweepBlocks = 113;

void main(List<String> arguments) {
  final path = arguments.isEmpty
      ? 'path/to/srtm1z/N39W105.hgtz'
      : arguments.single;
  final bytes = File(path).readAsBytesSync();
  final header = ByteData.sublistView(bytes);
  final rows = header.getUint16(6);
  final columns = header.getUint16(8);
  final block = header.getUint16(10);
  final blockColumns = (columns + block - 1) ~/ block;
  final blockRows = (rows + block - 1) ~/ block;

  // Only the square blocks, so every timing is over the same 131,072 bytes.
  final full = <Uint8List>[];
  for (var index = 0; index < blockRows * blockColumns; index++) {
    final entry = 12 + 8 * index;
    final top = (index ~/ blockColumns) * block;
    final left = (index % blockColumns) * block;
    if (rows - top < block || columns - left < block) {
      continue;
    }
    final offset = header.getUint32(entry);
    full.add(
      Uint8List.sublistView(
        bytes,
        offset,
        offset + header.getUint32(entry + 4),
      ),
    );
  }
  if (full.isEmpty) {
    stderr.writeln('$path has no full $block by $block block');
    exit(2);
  }

  final decoder = ZstdDecoder();
  final size = decoder.decode(full.first).length;
  stdout.writeln(path);
  stdout.writeln(
    '${full.length} full blocks of $size bytes, '
    '${(full.map((f) => f.length).reduce((a, b) => a + b) / full.length).round()}'
    ' compressed bytes on average',
  );

  // One block, over and over. The same frame every time, so the caches are as
  // warm as they will ever be. This is the optimistic figure.
  final one = full[full.length ~/ 2];
  for (var i = 0; i < 300; i++) {
    decoder.decode(one);
  }
  final repeated = <int>[];
  for (var i = 0; i < 1000; i++) {
    final watch = Stopwatch()..start();
    decoder.decode(one);
    watch.stop();
    repeated.add(watch.elapsedMicroseconds);
  }
  _report('one block repeated, warm', repeated, size);

  // Every full block once, which is the mix a real sweep meets: different
  // entropy tables, different literal counts, different sequence counts.
  final each = <int>[];
  for (var pass = 0; pass < 8; pass++) {
    for (final frame in full) {
      final watch = Stopwatch()..start();
      decoder.decode(frame);
      watch.stop();
      if (pass > 0) {
        each.add(watch.elapsedMicroseconds);
      }
    }
  }
  _report('every full block, warm', each, size);

  // A sweep as one unit, since that is the latency the user feels.
  final sweeps = <int>[];
  for (var pass = 0; pass < 30; pass++) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < sweepBlocks; i++) {
      decoder.decode(full[i % full.length]);
    }
    watch.stop();
    sweeps.add(watch.elapsedMicroseconds);
  }
  sweeps.sort();
  final sweep = sweeps[sweeps.length ~/ 2] / 1000;
  stdout.writeln(
    '$sweepBlocks block sweep, median      ${sweep.toStringAsFixed(2)} ms '
    '(${(sweep / sweepBlocks * 1000).toStringAsFixed(0)} us per block)',
  );
}

void _report(String label, List<int> microseconds, int size) {
  microseconds.sort();
  final median = microseconds[microseconds.length ~/ 2];
  final low = microseconds[microseconds.length ~/ 10];
  final high = microseconds[microseconds.length * 9 ~/ 10];
  final mbPerSecond = size / median; // bytes per microsecond is MB/s.
  stdout.writeln(
    '${label.padRight(28)} ${(median / 1000).toStringAsFixed(3)} ms '
    'median  (p10 ${(low / 1000).toStringAsFixed(3)}, '
    'p90 ${(high / 1000).toStringAsFixed(3)}, '
    'n=${microseconds.length})  ${mbPerSecond.toStringAsFixed(0)} MB/s',
  );
}
