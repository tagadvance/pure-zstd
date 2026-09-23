import 'dart:typed_data';

import 'package:pure_zstd/pure_zstd.dart';
import 'package:test/test.dart';

import 'corpus.dart';

/// The shapes whose frames are too large to commit.
///
/// Each input is built here from a seeded generator and handed to the `zstd`
/// CLI, so the frame is libzstd's own output and the expectation is the exact
/// bytes that went in. The round trip is the oracle; nothing is asserted
/// against what this decoder happens to produce.
///
/// The shapes matter because the real `.hgtz` corpus is 16,490 blocks from
/// one producer at one level, and none of this appears in it:
///
/// * short tokens from a small pool put more than 32,512 sequences in one
///   block, which is the only thing that writes the three-byte sequence
///   count. The pool size decides which sequence tables libzstd picks: 200
///   tokens gets RLE and repeat tables for the literal lengths, 2,000 gets an
///   RLE table for the match lengths;
/// * incompressible noise at a low level makes libzstd give up and emit raw
///   blocks and raw literals;
/// * a lopsided alphabet with no matches makes it build one Huffman table and
///   have the blocks that follow reuse it, which is treeless literals.
void main() {
  // 600 KB each, as 200,000 three-byte tokens drawn from a pool.
  final Uint8List narrowTokens = tokenStream(
    tokens: 200,
    tokenLength: 3,
    count: 200000,
  );
  final Uint8List wideTokens = tokenStream(
    tokens: 2000,
    tokenLength: 3,
    count: 200000,
  );

  // 200 KB of noise, which no compressor can do anything with.
  final Uint8List random = noise(200000);

  final shapes = <String, ({List<String> arguments, Uint8List input})>{
    'zstd --ultra -22 --zstd=minMatch=3 over 600 KB of 3-byte tokens, '
        'pool 200': (
      arguments: ['--ultra', '-22', '--zstd=minMatch=3'],
      input: narrowTokens,
    ),
    'zstd -19 --zstd=minMatch=3 over 600 KB of 3-byte tokens, pool 200': (
      arguments: ['-19', '--zstd=minMatch=3'],
      input: narrowTokens,
    ),
    'zstd -19 --zstd=minMatch=3 over 600 KB of 3-byte tokens, pool 2000': (
      arguments: ['-19', '--zstd=minMatch=3'],
      input: wideTokens,
    ),
    'zstd -1 over 200 KB of noise': (arguments: ['-1'], input: random),
    'zstd --fast=5 over 200 KB of noise': (
      arguments: ['--fast=5'],
      input: random,
    ),
    'zstd -3 over 300 KB of a skewed alphabet': (
      arguments: ['-3'],
      input: skewedAlphabet(300000),
    ),
  };

  group(
    'a frame libzstd wrote decodes back to what went in',
    () {
      for (final shape in shapes.entries) {
        test(shape.key, () {
          final frame = zstdCli(shape.value.arguments, shape.value.input);
          final out = ZstdDecoder().decode(frame);
          expect(out.length, shape.value.input.length);
          expect(out, orderedEquals(shape.value.input));
        }, timeout: const Timeout(Duration(minutes: 2)));
      }
    },
    skip: hasZstdCli ? null : 'the zstd CLI is not on the path',
  );
}
