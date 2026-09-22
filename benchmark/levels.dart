// Times several extracted-block files against each other, interleaved, so that
// CPU frequency drift lands on every file equally.
//
//     dart compile exe levels.dart -o /tmp/levels && /tmp/levels a.blocks b.blocks
//
// Each file is the format benchmark/same_blocks.dart reads: uint32 count, then
// per block a uint32 frame length, a uint32 decompressed size, and the frame.
// Every file must hold the same number of blocks, of the same output size, so
// the medians are like for like.
import 'dart:io';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';

const int warmSeconds = 4;
const int passes = 60;

List<Uint8List> load(String path, List<int> sizes) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(0, Endian.big);
  final frames = <Uint8List>[];
  var at = 4;
  for (var i = 0; i < count; i++) {
    final length = data.getUint32(at, Endian.big);
    final size = data.getUint32(at + 4, Endian.big);
    if (sizes.length <= i) {
      sizes.add(size);
    } else if (sizes[i] != size) {
      throw StateError(
        '$path block $i is $size bytes out, expected ${sizes[i]}',
      );
    }
    at += 8;
    frames.add(Uint8List.sublistView(bytes, at, at + length));
    at += length;
  }
  return frames;
}

void main(List<String> args) {
  final sizes = <int>[];
  final sets = args.map((path) => load(path, sizes)).toList();
  for (final set in sets) {
    if (set.length != sets.first.length) {
      throw StateError('the files do not hold the same number of blocks');
    }
    for (var i = 0; i < set.length; i++) {
      if (zstdDecode(set[i]).length != sizes[i]) {
        throw StateError('block $i decoded to the wrong size');
      }
    }
  }

  // Spin long enough for the governor to raise the clock before anything is
  // timed, otherwise the first file measured pays for the ramp.
  final warm = Stopwatch()..start();
  while (warm.elapsed.inSeconds < warmSeconds) {
    for (final set in sets) {
      for (final frame in set) {
        zstdDecode(frame);
      }
    }
  }

  final micros = [for (final _ in sets) <int>[]];
  for (var pass = 0; pass < passes; pass++) {
    for (var b = 0; b < sets.first.length; b++) {
      for (var s = 0; s < sets.length; s++) {
        final watch = Stopwatch()..start();
        zstdDecode(sets[s][b]);
        watch.stop();
        micros[s].add(watch.elapsedMicroseconds);
      }
    }
  }

  for (var s = 0; s < sets.length; s++) {
    final xs = micros[s]..sort();
    double q(double f) => xs[(xs.length * f).floor()] / 1000;
    final median = q(0.5);
    final bytes = sizes.reduce((a, b) => a + b) / sizes.length;
    stdout.writeln(
      '${args[s].split('/').last.padRight(24)} n=${xs.length} '
      'median=${median.toStringAsFixed(3)}ms '
      'p10=${q(0.1).toStringAsFixed(3)} p90=${q(0.9).toStringAsFixed(3)} '
      'MBps=${(bytes / 1048576 / (median / 1000)).toStringAsFixed(0)} '
      'sweep113=${(median * 113).toStringAsFixed(0)}ms',
    );
  }
}
