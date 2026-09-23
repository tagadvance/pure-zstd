# Changelog

## 1.0.0

First release.

A zstd decompressor in plain Dart. Decompression only, native platforms only,
one frame per call.

- Decodes RFC 8878 frames: raw, RLE and compressed blocks; raw, RLE, compressed
  and treeless literals in one-stream and four-stream form; Huffman weights in
  both the direct nibble and FSE-coded forms; predefined, RLE, FSE and repeat
  sequence tables for all three symbols; repeated offsets including the
  no-literals shift; multi-block frames reusing an earlier block's tables.
- Verifies the content checksum when a frame carries one, with XXH64 in
  `lib/src/xxhash.dart`.
- Refuses dictionaries, several frames in one buffer, and any input left over
  after a frame.
- Bounds what a frame header can make it allocate. `ZstdDecoder` takes a
  `maxOutputSize`, 64 MiB by default, and a caller passing `expectedSize` gets
  an exact check against the frame's own declared size.
- Every failure is a `ZstdException`.

Correctness is measured against libzstd through pyzstd rather than against
expectations written by hand: 2,615 blocks of real elevation data across 32
containers, plus a committed corpus of 23 cases covering the format branches
that real data never reaches. 131 tests.

Roughly four times slower than native zstd. On a Pixel 10 Pro XL, profile AOT,
a 128 KiB block decodes in 0.414 ms, which is 302 MB/s.
