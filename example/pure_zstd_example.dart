import 'dart:convert';
import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';

/// `zstd -19` over a file holding `Hello from pure_zstd!`, with a checksum.
final Uint8List frame = Uint8List.fromList([
  0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x15, 0xa9, 0x00, 0x00, 0x48, 0x65, 0x6c, //
  0x6c, 0x6f, 0x20, 0x66, 0x72, 0x6f, 0x6d, 0x20, 0x70, 0x75, 0x72, 0x65,
  0x5f, 0x7a, 0x73, 0x74, 0x64, 0x21, 0x02, 0x01, 0xd0, 0x63,
]);

void main() {
  // One frame: the top-level function is enough.
  print(utf8.decode(zstdDecode(frame)));

  // Many frames: hold a decoder, which reuses its tables and scratch buffers.
  final decoder = ZstdDecoder();
  for (var i = 0; i < 3; i++) {
    print(utf8.decode(decoder.decode(frame)));
  }

  // Anything malformed is a ZstdException, never an Error.
  try {
    zstdDecode(Uint8List.fromList([...frame, 0x00]));
  } on ZstdException catch (error) {
    print(error);
  }
}
