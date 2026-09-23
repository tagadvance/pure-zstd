import 'dart:io';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';

/// Decodes every `*.zst` in a directory and compares it to the `*.raw`
/// beside it. Driven by tool/oracle.py, which writes the pair.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('usage: verify.dart <directory>');
    exit(2);
  }
  final directory = Directory(arguments.single);
  final frames =
      directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.zst'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final decoder = ZstdDecoder();
  var checked = 0;
  var bytes = 0;
  for (final frame in frames) {
    final expected = File(
      frame.path.replaceRange(frame.path.length - 4, null, '.raw'),
    ).readAsBytesSync();
    final Uint8List actual;
    try {
      actual = decoder.decode(frame.readAsBytesSync());
    } on ZstdException catch (error) {
      stderr.writeln('${frame.path}: $error');
      exit(1);
    }
    if (actual.length != expected.length) {
      stderr.writeln(
        '${frame.path}: ${actual.length} bytes, expected ${expected.length}',
      );
      exit(1);
    }
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) {
        stderr.writeln('${frame.path}: byte $i differs');
        exit(1);
      }
    }
    checked++;
    bytes += actual.length;
  }
  stdout.writeln('$checked frames, $bytes bytes, identical');
}
