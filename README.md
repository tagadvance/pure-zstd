# pure_zstd

[![CI](https://github.com/tagadvance/pure-zstd/actions/workflows/ci.yml/badge.svg)](https://github.com/tagadvance/pure-zstd/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/pure_zstd.svg)](https://pub.dev/packages/pure_zstd)
[![pub points](https://img.shields.io/pub/points/pure_zstd)](https://pub.dev/packages/pure_zstd/score)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.8-blue)](https://dart.dev)
[![License: MIT](https://img.shields.io/github/license/tagadvance/pure-zstd)](LICENSE)

A zstd decompressor in plain Dart, with no native dependency.

It exists because every zstd binding on pub.dev is a wrapper over libzstd, and
an app that reads block-compressed elevation tiles on a phone would rather not
carry a native library per platform to do it. Decompression only. There is no
compressor and there is no plan for one.

It decodes the real data it was written for, correctly and completely, and it
is roughly four times slower than native zstd. See **Speed** below before
depending on it.

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
| Content checksum | Verified. XXH64 over the output, compared with the stored low 32 bits. Hashed only when the frame carries one. |
| Dictionaries | Refused. |
| Skippable frames, several frames in one buffer | Refused. Reading one frame is the whole API, and input left over after it is an error. |
| Streaming, or decoding part of a frame | Not offered. |

It targets native Dart and not the web: the literals header reads a five-byte
field with a 32-bit shift, and the bit reader carries 56 bits in an `int`.
Both are exact on the VM and on AOT, and neither is on JavaScript.

## Correctness

The reference is pyzstd, which wraps libzstd. `tool/oracle.py` extracts every
block of a `.hgtz` container as its own frame, decompresses it with pyzstd,
hands it to `tool/verify.dart`, and compares byte for byte.

    ./tool/oracle.py <a .hgtz container>
    ./tool/oracle.py --every 1700 <a directory of them>

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

MIT. See [LICENSE](LICENSE).

## Acknowledgements

This is an independent implementation. It contains no code from libzstd, and
nothing about its licence reaches this package. It would not exist without the
following, and they are named here because that is where the debt actually is.

**[RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html), "Zstandard
Compression and the application/zstd Media Type"**, by Yann Collet and Murray
Kucherawy, is the specification this was written from. Every table in
`lib/src/tables.dart` was checked against section 3.1.1.3.2 entry by entry, and
the FSE and Huffman decoders follow the reference algorithms it describes. A
format specification written clearly enough to implement from is a gift, and
this one is.

**[Zstandard](https://github.com/facebook/zstd)**, by Yann Collet and
contributors at Meta, is the format and the reference implementation. Its
licence is BSD-3-Clause, and it obliges nothing here; it is named because
without it there would be nothing to decode.

**[pyzstd](https://pypi.org/project/pyzstd/)** wraps libzstd and is the oracle
every test in this package is measured against. Correctness here means
"agrees with libzstd, byte for byte", and pyzstd is how that is asked. The
committed fixtures under `test/fixtures/corpus/` are output of the `zstd` CLI
and of pyzstd, which is tool output rather than anything derived from their
source.

**The Copernicus Programme.** One committed fixture,
`test/fixtures/corpus/direct_nibble.zst`, is a block of real terrain, kept
because it is the only small input that exercises the direct-nibble Huffman
weight form. Its licence requires this to travel with it:

> Produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved.

**The Dart team**, for making `int` an exact 64-bit integer on the VM and on
AOT. The bit reader carries 56 bits in one and XXH64's multiplies wrap exactly,
neither of which would be true on a platform with doubles underneath.

## Measured on the target device, 2026-09-21

Sixteen real 256x256 blocks lifted out of one elevation container,
131,072 bytes of output each, the same blocks in every row so the numbers are
comparable. Median of 960 timed calls after 320 warm-up calls.

| where | mode | median | MB/s | 113-block sweep |
| --- | --- | --- | --- | --- |
| Pixel 10 Pro XL | **profile, AOT** | **0.414 ms** | 302 | **47 ms** |
| Pixel 10 Pro XL | debug, JIT | 0.540 ms | 231 | 61 ms |
| this laptop | AOT | 0.917 ms | 136 | 104 ms |
| this laptop | JIT | 1.125 ms | 111 | 127 ms |

The phone is about twice as fast as the laptop at this, which is why the
desktop figures in the commit message read worse than reality.

Native, for scale: pyzstd on the laptop is 0.175 ms on comparable blocks. That
is a Python C extension rather than Dart FFI, so take it as an indication. No
native-on-phone figure was taken.

Do not benchmark against `test/fixtures/N51E000.hgtz`. Its samples are a
synthetic pattern that compresses to almost no sequences, and decode cost
tracks sequence count, so it reads about six times too fast. That mistake was
made once already.

---

If this saved you some time, please consider [sponsoring the work](https://github.com/sponsors/tagadvance).
