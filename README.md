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
| Skippable frames, several frames in one buffer | Only a *leading* skippable frame is refused, and only because the magic check fires. See **Known defects**. |
| Streaming, or decoding part of a frame | Not offered. |

It targets native Dart and not the web: the literals header reads a five-byte
field with a 32-bit shift, and the bit reader carries 56 bits in an `int`.
Both are exact on the VM and on AOT, and neither is on JavaScript.

## Known defects

Found by two audits on 2026-09-21, confirmed with reproducers, and **not yet
fixed**. Nothing should depend on this package until they are.

1. **`Frame_Content_Size` sizes the output allocation with no ceiling.** A
   16-byte frame can ask for 4 EiB. One bit flipped in the frame descriptor of a
   real tile gives `RangeError` or `OutOfMemoryError`, and neither is catchable
   as `ZstdException`, so the isolate dies. This is what the skipped
   `Window_Descriptor` was for: RFC 8878 §3.1.1.1.2 allows a decoder to refuse a
   frame asking for more memory than it will give. Require the declared size to
   be under a stated ceiling, and have the `.hgtz` reader pass the exact
   `height * width * 2` it expects.
2. **`fseDecodeInterleaved` writes three symbols in a pass that checks room for
   two.** `fse.dart:210` guards on `at + 2 > outLimit` and the exhausted branch
   writes a third, so a crafted Huffman weight stream indexes `_weights[256]`.
   The reproducer is 53 bytes, and random mutation of a real tile found it
   independently. The guard wants `at + 3`.
3. **Several frames in one buffer decode to the first and return silently.** The
   block loop breaks on the last block and nothing compares the cursor with the
   input length, so a second frame, a trailing skippable frame, and four junk
   bytes appended are all accepted and ignored. Require the cursor to have
   reached the end.
4. **RLE blocks skip the block-size ceiling.** `type != 1` exempts them, so 97
   bytes of input returns 44 MB of output that a caller cannot tell from a good
   tile.
5. **The content checksum is parsed and never verified.** Over 600,000
   mutations of real block data, 34% decoded into wrong bytes with no error
   raised. A frame may also claim a checksum and supply none, because the four
   bytes are stepped over rather than read. `hgtz.py` writes no checksum either,
   so a corrupt tile on a phone becomes wrong elevation rather than an error.
   This is the one that makes the rest systemic: it is the only mechanism that
   would catch a wrong decode from anything else.

Over-permissive against libzstd, with no wrong output, so lower priority: a
compressed block over `blockSizeMax` is accepted, the Huffman weight table is
read with `maxSymbol` 255 where libzstd uses 12, and `Regenerated_Size` is
capped at a flat 128 KiB rather than `min(Window_Size, 128 KiB)`.

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

## Measured on the target device, 2026-09-21

Sixteen real 256x256 blocks lifted out of `path/to/srtm1z/N39W105.hgtz`,
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
