# pure_zstd

A zstd decompressor in plain Dart, with no native dependency.

It exists because every zstd binding on pub.dev is a wrapper over libzstd, and
an app that reads block-compressed elevation tiles on a phone would rather not
carry a native library per platform to do it. Decompression only. There is no
compressor and there is no plan for one.

This is a feasibility spike, not a finished library. It decodes the real data
it was written for, correctly and completely, and it is roughly four times
slower than native zstd. See **Speed** below before depending on it.

## Using it

```dart
import 'package:pure_zstd/pure_zstd.dart';

final plain = zstdDecode(frame);

// Decoding many frames: hold the decoder, which keeps its entropy tables and
// scratch buffers between calls and then allocates only the output.
final decoder = ZstdDecoder();
for (final frame in frames) {
  use(decoder.decode(frame));
}
```

A frame that declares no content size needs `expectedSize`, because the
output is allocated whole rather than grown.

## What it implements

RFC 8878 is the specification. Of it:

| Part of the format | State |
| --- | --- |
| Frame header, single segment and windowed | Decoded. The window descriptor is skipped, since the output is allocated from the content size. |
| Raw, RLE and compressed blocks | All three. |
| Multi-block frames | Yes, including a later block reusing an earlier one's tables and recent offsets. |
| Raw, RLE, compressed and treeless literals | All four, in one-stream and four-stream form. |
| Huffman weights | Both the direct nibble form and the FSE-coded form. |
| Sequence tables | Predefined, RLE, FSE-compressed and repeat, for all three of literal length, match length and offset. |
| Repeated offsets | Yes, including the no-literals shift. |
| Content checksum | Parsed and **skipped, never verified**. |
| Dictionaries | Refused. |
| Skippable frames, several frames in one buffer | Refused. Reading one frame is the whole API. |
| Streaming, or decoding part of a frame | Not offered. |

It targets native Dart and not the web: the literals header reads a five-byte
field with a 32-bit shift, and the bit reader carries 56 bits in an `int`.
Both are exact on the VM and on AOT, and neither is on JavaScript.

## Correctness

The reference is pyzstd, which wraps libzstd. `tool/oracle.py` extracts every
block of a `.hgtz` container as its own frame, decompresses it with pyzstd,
hands it to `tool/verify.dart`, and compares byte for byte.

    ./tool/oracle.py path/to/srtm1z/N39W105.hgtz
    ./tool/oracle.py --every 1700 path/to/srtm1z path/to/srtm3z

As of 2026-09-21 that is 32 real containers, 2,615 blocks and 0.3 GB of
output, all identical, spanning both the one and three arc-second sets, every
thinned column count from 3601 down to 361, and latitudes from 88 S to 80 N.

`dart test` needs no Python. It decodes the five blocks of the container in
`test/fixtures/`, whose every sample is a known function of its position, so a
wrong decode cannot pass.

## Speed

Measured 2026-09-21 on this eight-core Linux box, `dart compile exe`, Dart
3.12.2. One 256 by 256 block is 131,072 bytes out. The frames are read into
memory first, so only decoding is timed, and the figure includes allocating
the output buffer because the API allocates it.

| Block set | pure_zstd, AOT | pyzstd (libzstd) |
| --- | --- | --- |
| Colorado, `N39W105`, 196 blocks, median | **0.66 ms** | 0.18 ms |
| Alaska, `N60W160`, 98 blocks, median | 0.94 ms | not measured |
| One block, repeated 1000 times | 0.85 ms | 0.22 ms |
| 113 blocks, a 360 degree sweep | 67 ms | 19 ms |

That is 140 to 200 MB/s of output. The JIT is about 25% slower than AOT, so
measure with `dart compile exe`.

The cost is almost all in the sequence loop rather than in Huffman literals.
A block of real terrain carries around 1,700 literals and 14,400 sequences,
so the hot path is three FSE state updates, six bit reads and a nine-byte
match copy, about 46 ns per sequence against native's dozen or so. The
headroom left is bounds checks and the byte-at-a-time match copy; widening
that copy to 64-bit words, the way libzstd does, is the next thing to try.

Run it yourself:

    dart compile exe benchmark/bench.dart -o /tmp/bench && /tmp/bench

## Licence

Not chosen yet.
