// Times the same extracted blocks the on-device benchmark uses, so the two
// numbers are like for like.
import 'dart:io';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';

void main(List<String> args) {
  final bytes = File(args.first).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(0, Endian.big);
  final frames = <Uint8List>[];
  final sizes = <int>[];
  var at = 4;
  for (var i = 0; i < count; i++) {
    final length = data.getUint32(at, Endian.big);
    sizes.add(data.getUint32(at + 4, Endian.big));
    at += 8;
    frames.add(Uint8List.sublistView(bytes, at, at + length));
    at += length;
  }
  for (var i = 0; i < frames.length; i++) {
    if (zstdDecode(frames[i]).length != sizes[i]) {
      throw StateError('block $i decoded to the wrong size');
    }
  }
  for (var pass = 0; pass < 20; pass++) {
    for (final frame in frames) {
      zstdDecode(frame);
    }
  }
  final micros = <int>[];
  for (var pass = 0; pass < 60; pass++) {
    for (final frame in frames) {
      final watch = Stopwatch()..start();
      zstdDecode(frame);
      watch.stop();
      micros.add(watch.elapsedMicroseconds);
    }
  }
  micros.sort();
  double q(double f) => micros[(micros.length * f).floor()] / 1000;
  final median = q(0.5);
  stdout.writeln(
    'samples=${micros.length} bytesOut=${sizes.first} '
    'median=${median.toStringAsFixed(3)}ms p10=${q(0.1).toStringAsFixed(3)} '
    'p90=${q(0.9).toStringAsFixed(3)} '
    'MBps=${(sizes.first / 1048576 / (median / 1000)).toStringAsFixed(0)} '
    'sweep113=${(median * 113).toStringAsFixed(0)}ms',
  );
}
