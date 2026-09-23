import 'dart:typed_data';

import 'package:pure_zstd/src/xxhash.dart';
import 'package:test/test.dart';

// Every digest below came from the `xxhash` Python package, version 3.0.0,
// which wraps the reference C implementation. The two byte generators are
// written identically on both sides, so the inputs are reproducible here
// without carrying the bytes themselves.
//
// The lengths are chosen around the boundaries of the tail, which is
// consumed in 32-byte stripes, then 8, then 4, then 1. Each of those is a
// separate branch and each gets a length either side of it.

/// A repeating pattern. 251 is prime, so it does not line up with the stripe.
Uint8List _pattern(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i % 251));

/// Bytes with no structure, from a deterministic generator rather than
/// `Random`, so the expected digests stay valid.
Uint8List _pseudoRandom(int length) {
  final out = Uint8List(length);
  var x = 1;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = (x >> 16) & 0xFF;
  }
  return out;
}

const List<(int, int)> _patternDigests = [
  (0, 0xEF46DB3751D8E999),
  (1, 0xE934A84ADB052768),
  (2, 0x4865A00BA85B7CD6),
  (3, 0xE5C7BB4533BC65DD),
  (4, 0xFFCED8604453CC1E),
  (5, 0xDD0274386E26030C),
  (7, 0x14CC643F630C72D2),
  (8, 0x884A173614B81B8D),
  (9, 0x67D85784A7C78C5B),
  (15, 0xA948F5F0F6ABAC2D),
  (16, 0x44B6EF2FB84169F7),
  (17, 0x5603E60C527599B6),
  (31, 0xC346D2B59B4D8EE1),
  (32, 0xCBF59C5116FF32B4),
  (33, 0x0C535D1ACAFB8EAD),
  (63, 0xE26AA9E2A95F8E4F),
  (64, 0xF7C67301DB6713F0),
  (65, 0xC31EB63B2AE4465B),
  (127, 0x464D085810CE0199),
  (128, 0x7A7FE14647B9AB92),
  (129, 0x0BA25DFD6E891FCF),
  (255, 0x566D96B832B967C1),
  (256, 0xF33944343EE85824),
  (1000, 0xF306F04AA88B54D3),
  (4096, 0x122A8C8D994AD3EC),
  (5000, 0xA6833D648FD6A332),
];

const List<(int, int)> _pseudoRandomDigests = [
  (0, 0xEF46DB3751D8E999),
  (1, 0xD2DA77930F69647C),
  (2, 0x9F33D4BD50F99C34),
  (3, 0xF7C331CF2042B940),
  (4, 0x1B042F821FC4A793),
  (5, 0x6E1F98107D9DB571),
  (7, 0x41D39023940006C8),
  (8, 0xEF7823FCE4AD9AFB),
  (9, 0x81CF88E9D8340150),
  (15, 0x6F0095B1C00E82FB),
  (16, 0x29965039DF6047BB),
  (17, 0x5236FCB96D8FB228),
  (31, 0x68C3DBB752F3FA97),
  (32, 0xAD7DC5A569BB047C),
  (33, 0x475B642AC692E380),
  (63, 0xC18C4743DE1B99A8),
  (64, 0x06872C5D6370DE25),
  (65, 0x8B5F4E34A32C5A09),
  (127, 0x77DC651915D836B5),
  (128, 0x2E9C4CB0B29BC8EC),
  (129, 0xB5E3A45BFF735CFA),
  (255, 0x9AD1F660B88ABC38),
  (256, 0x9AE30993C3F4B05A),
  (1000, 0x7AD5B044FB6FA81D),
  (4096, 0x4AFD74BF8BD52DF5),
  (5000, 0xCAEF4049E5C55187),
];

/// `Mt Herman 2764 m\n` 241 times, through `zstd -19 --check`. The frame is
/// embedded whole so the trailing `Content_Checksum` is read from a real
/// frame rather than asserted from a constant.
const String _checkedFrame =
    '28b52ffd64010fcd0000884d74204865726d616e2032373634206d0a01'
    '00db4ffe5c02fe13e790';

Uint8List _hex(String text) {
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('xxh64 in one shot', () {
    for (final (length, expected) in _patternDigests) {
      test('matches the reference over $length repeating bytes', () {
        expect(xxh64(_pattern(length)), expected);
      });
    }

    for (final (length, expected) in _pseudoRandomDigests) {
      test('matches the reference over $length unstructured bytes', () {
        expect(xxh64(_pseudoRandom(length)), expected);
      });
    }

    test('honours a seed, including one that is negative as a Dart int', () {
      expect(xxh64(_pattern(0), seed: 1), 0xD5AFBA1336A3BE4B);
      expect(xxh64(_pattern(5), seed: 1), 0x27CE45508B78A340);
      expect(xxh64(_pattern(32), seed: 1), 0xD74E6766CE9DBA94);
      expect(xxh64(_pattern(200), seed: 1), 0x20BD094800CB1DFA);

      const seed = 0x9E3779B185EBCA87;
      expect(seed.isNegative, isTrue);
      expect(xxh64(_pattern(0), seed: seed), 0x6EC6D05F61C7E7A7);
      expect(xxh64(_pattern(5), seed: seed), 0xF60DC54C180A9098);
      expect(xxh64(_pattern(32), seed: seed), 0xBFB3E4EF6096C49C);
      expect(xxh64(_pattern(200), seed: seed), 0x6EA98426E0B64F4A);
    });
  });

  group('the incremental form', () {
    // Lengths either side of every boundary, plus enough stripes that a
    // chunking can straddle several.
    const lengths = [
      0,
      1,
      3,
      4,
      7,
      8,
      15,
      16,
      31,
      32,
      33,
      63,
      64,
      65,
      127,
      128,
      129,
      1000,
      4096,
      5001,
    ];

    for (final chunk in [1, 3, 7, 8, 17, 31, 32, 33, 64, 250]) {
      test('in $chunk-byte chunks equals the one shot', () {
        for (final length in lengths) {
          final data = _pseudoRandom(length);
          final hash = Xxh64();
          for (var at = 0; at < length; at += chunk) {
            final end = at + chunk < length ? at + chunk : length;
            hash.update(data, at, end);
          }
          expect(hash.digest, xxh64(data), reason: '$length bytes');
        }
      });
    }

    test('ignores empty chunks, leading, trailing and interleaved', () {
      final data = _pattern(300);
      final empty = Uint8List(0);
      final hash = Xxh64()
        ..update(empty)
        ..update(data, 0, 1)
        ..update(empty)
        ..update(data, 1, 40)
        ..update(data, 40, 40)
        ..update(data, 40, 300)
        ..update(empty);
      expect(hash.digest, xxh64(data));
    });

    test('accepts a whole list with no range', () {
      final data = _pattern(100);
      final hash = Xxh64()
        ..update(Uint8List.sublistView(data, 0, 37))
        ..update(Uint8List.sublistView(data, 37));
      expect(hash.digest, xxh64(data));
    });

    test('reads the same digest twice and keeps hashing afterwards', () {
      final data = _pattern(500);
      final hash = Xxh64()..update(data, 0, 200);
      expect(hash.digest, xxh64(_pattern(200)));
      expect(hash.digest, xxh64(_pattern(200)));
      hash.update(data, 200, 500);
      expect(hash.digest, xxh64(data));
    });

    test('reset returns it to the state of a fresh instance', () {
      final hash = Xxh64()..update(_pattern(999));
      hash.reset();
      expect(hash.digest, xxh64(_pattern(0)));
      hash.update(_pattern(65));
      expect(hash.digest, xxh64(_pattern(65)));
    });

    test('rejects a range outside the list', () {
      expect(() => Xxh64().update(_pattern(10), 0, 11), throwsRangeError);
      expect(() => Xxh64().update(_pattern(10), -1), throwsRangeError);
      expect(() => Xxh64().update(_pattern(10), 6, 5), throwsRangeError);
    });
  });

  group('a real zstd frame', () {
    final frame = _hex(_checkedFrame);
    final content = Uint8List.fromList(
      List.filled(
        241,
        'Mt Herman 2764 m\n'.codeUnits,
      ).expand((e) => e).toList(),
    );

    test('declares a content checksum', () {
      expect((frame[4] >> 2) & 1, 1);
    });

    test('ends with the low 32 bits of the content digest', () {
      final stored = ByteData.sublistView(
        frame,
        frame.length - 4,
      ).getUint32(0, Endian.little);
      expect((Xxh64()..update(content)).digest32, stored);
      expect(xxh64(content) & 0xFFFFFFFF, stored);
    });
  });
}
