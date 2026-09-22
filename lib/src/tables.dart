/// The fixed tables RFC 8878 defines for sequence decoding.
library;

import 'dart:typed_data';

/// Literals length code to the smallest length it can mean.
final Int32List literalLengthBaseline = Int32List.fromList(const <int>[
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, //
  48, 64, 128, 256, 512, 1024, 2048, 4096, //
  8192, 16384, 32768, 65536,
]);

/// Extra bits read after a literals length code.
final Uint8List literalLengthExtra = Uint8List.fromList(const <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, //
  4, 6, 7, 8, 9, 10, 11, 12, //
  13, 14, 15, 16,
]);

/// Match length code to the smallest length it can mean.
final Int32List matchLengthBaseline = Int32List.fromList(const <int>[
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, //
  35, 37, 39, 41, 43, 47, 51, 59, //
  67, 83, 99, 131, 259, 515, 1027, 2051, //
  4099, 8195, 16387, 32771, 65539,
]);

/// Extra bits read after a match length code.
final Uint8List matchLengthExtra = Uint8List.fromList(const <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, //
  4, 4, 5, 7, 8, 9, 10, 11, //
  12, 13, 14, 15, 16,
]);

/// The default literals length distribution, accuracy log 6.
const List<int> literalLengthDefault = <int>[
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1,
];

/// The default match length distribution, accuracy log 6.
const List<int> matchLengthDefault = <int>[
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, //
  -1, -1, -1, -1, -1,
];

/// The default offset code distribution, accuracy log 5.
const List<int> offsetCodeDefault = <int>[
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
];

const int literalLengthMaxLog = 9;
const int matchLengthMaxLog = 9;
const int offsetCodeMaxLog = 8;

const int literalLengthMaxSymbol = 35;
const int matchLengthMaxSymbol = 52;
const int offsetCodeMaxSymbol = 31;
