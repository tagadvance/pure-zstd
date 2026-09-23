import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Loading and generating the test corpus.
///
/// The committed half lives in `test/fixtures/corpus`, built by
/// `tool/make_corpus.py`. Every frame there was either written by libzstd or
/// hand-built and then accepted by pyzstd, and the expected plain bytes of a
/// legal frame are what pyzstd decompressed it to, gzipped. `manifest.json`
/// records the exact command behind each one, so a fixture is never a blob
/// nobody can reproduce.
///
/// The half that is too large to commit is generated here instead, from the
/// seeded generator below and the `zstd` CLI.
const String corpusDirectory = 'test/fixtures/corpus';

/// One entry of `manifest.json`.
class CorpusCase {
  CorpusCase(Map<String, Object?> json)
    : name = json['name']! as String,
      command = json['command']! as String,
      frameFile = json['frame']! as String,
      legal = json['verdict'] == 'legal',
      why = json['why'] as String?,
      derive = json['derive'] as String?,
      size = json['size'] as int?,
      expectedSize = json['expectedSize'] as int?,
      trailing = json['trailing'] as String?,
      _plain = (json['plain'] as List<Object?>? ?? const [])
          .cast<String>()
          .toList();

  /// The case name, which is also the `test()` description.
  final String name;

  /// The exact command that produced the frame.
  final String command;

  final String frameFile;

  /// True when libzstd decompresses the frame, false when it refuses it.
  final bool legal;

  /// For a refused case, what is wrong with it and what pyzstd said.
  final String? why;

  /// For a refused case built by damaging another case's frame, the damage.
  final String? derive;

  /// Length of the plain bytes, for a legal case.
  final int? size;

  /// What the caller must pass to `decode`, for a frame declaring no content
  /// size of its own.
  final int? expectedSize;

  /// What follows the first frame, for a buffer libzstd reads as a stream of
  /// frames and this decoder reads as one frame and then leftovers.
  final String? trailing;

  final List<String> _plain;

  /// The frame, with any recorded damage applied.
  Uint8List get frame {
    final bytes = Uint8List.fromList(
      File('$corpusDirectory/$frameFile').readAsBytesSync(),
    );
    return switch (derive) {
      null => bytes,
      'the last checksum byte flipped' => Uint8List.fromList(
        bytes,
      )..[bytes.length - 1] ^= 0x01,
      'all four checksum bytes zeroed' => Uint8List.fromList(
        bytes,
      )..fillRange(bytes.length - 4, bytes.length, 0),
      'the last two bytes cut' => Uint8List.sublistView(
        bytes,
        0,
        bytes.length - 2,
      ),
      _ => throw StateError('unknown damage: $derive'),
    };
  }

  /// What pyzstd decompressed the frame to. Only for a legal case.
  Uint8List get plain {
    final out = BytesBuilder(copy: false);
    for (final part in _plain) {
      out.add(gzip.decode(File('$corpusDirectory/$part').readAsBytesSync()));
    }
    return out.takeBytes();
  }

  @override
  String toString() => '$name ($command)';
}

/// Every case in `manifest.json`, in the order the generator wrote them.
List<CorpusCase> loadCorpus() {
  final text = File('$corpusDirectory/manifest.json').readAsStringSync();
  return (jsonDecode(text) as List<Object?>)
      .cast<Map<String, Object?>>()
      .map(CorpusCase.new)
      .toList();
}

/// xorshift64, the same three shifts `tool/make_corpus.py` uses, so an input
/// built here and one built there are the same bytes.
class Xorshift64 {
  Xorshift64(this._state);

  int _state;

  int next() {
    var state = _state;
    state ^= state << 13;
    state ^= state >>> 7;
    state ^= state << 17;
    _state = state;
    return state;
  }

  Uint8List bytes(int count) {
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = (next() >>> 33) & 0xFF;
    }
    return out;
  }
}

/// `count` bytes of pseudo-random noise. Incompressible, so a compressor has
/// to fall back on raw blocks and raw literals.
Uint8List noise(int count, {int seed = 0x9E3779B97F4A7C15}) =>
    Xorshift64(seed).bytes(count);

/// A stream built by drawing `count` tokens of `tokenLength` bytes from a
/// pool of `tokens` of them.
///
/// Short tokens from a small pool are what puts tens of thousands of
/// sequences in one block: every token is a match, and at three bytes each
/// there are more of them than the two-byte sequence count can hold.
Uint8List tokenStream({
  required int tokens,
  required int tokenLength,
  required int count,
  int seed = 0x2545F4914F6CDD1D,
}) {
  final random = Xorshift64(seed);
  final pool = random.bytes(tokens * tokenLength);
  final out = Uint8List(count * tokenLength);
  for (var i = 0; i < count; i++) {
    final token = (random.next() >>> 16) % tokens;
    out.setRange(
      i * tokenLength,
      (i + 1) * tokenLength,
      pool,
      token * tokenLength,
    );
  }
  return out;
}

/// `count` bytes drawn from a lopsided alphabet: `a` eight times as likely as
/// the rare letters, and no matches to speak of.
///
/// This is the shape that makes libzstd build one Huffman table and then
/// reuse it for the blocks that follow, which is the treeless literals form.
Uint8List skewedAlphabet(int count, {int seed = 0x853C49E6748FEA9B}) {
  const alphabet = 'aaaaaaaabbbbccdefghijklmnopqrstuvwxyz';
  final random = Xorshift64(seed);
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    out[i] = alphabet.codeUnitAt((random.next() >>> 16) % alphabet.length);
  }
  return out;
}

/// True when the `zstd` CLI is on the path.
bool get hasZstdCli {
  try {
    return Process.runSync('zstd', const ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Compresses [input] with the `zstd` CLI, as `zstd -q -c <args> <file>`.
///
/// A file argument rather than a pipe, so the frame carries a content size.
Uint8List zstdCli(List<String> args, Uint8List input) {
  final directory = Directory.systemTemp.createTempSync('pure_zstd_corpus_');
  try {
    final file = File('${directory.path}/input.bin')..writeAsBytesSync(input);
    final run = Process.runSync('zstd', [
      '-q',
      '-c',
      ...args,
      file.path,
    ], stdoutEncoding: null);
    if (run.exitCode != 0) {
      throw StateError('zstd ${args.join(' ')} failed: ${run.stderr}');
    }
    return Uint8List.fromList(run.stdout as List<int>);
  } finally {
    directory.deleteSync(recursive: true);
  }
}
