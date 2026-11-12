import 'dart:math';
import 'dart:typed_data';

import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

Uint8List hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16)
    ]);

String toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Appendix A of RFC 8949.
  final vectors = <String, Object?>{
    '00': 0,
    '01': 1,
    '0a': 10,
    '17': 23,
    '1818': 24,
    '1819': 25,
    '1864': 100,
    '1903e8': 1000,
    '1a000f4240': 1000000,
    '1b000000e8d4a51000': 1000000000000,
    '20': -1,
    '29': -10,
    '3863': -100,
    '3903e7': -1000,
    'fb3ff199999999999a': 1.1,
    'fb7e37e43c8800759c': 1.0e+300,
    'fbc010666666666666': -4.1,
    'f4': false,
    'f5': true,
    'f6': null,
    '40': Uint8List(0),
    '4401020304': Uint8List.fromList([1, 2, 3, 4]),
    '60': '',
    '6161': 'a',
    '6449455446': 'IETF',
    '62c3bc': 'ü',
    '63e6b0b4': '水',
    '64f0908591': '𐅑',
    '80': <Object?>[],
    '83010203': [1, 2, 3],
    '8301820203820405': [
      1,
      [2, 3],
      [4, 5]
    ],
    'a0': <Object?, Object?>{},
    'a201020304': {1: 2, 3: 4},
    'a26161016162820203': {
      'a': 1,
      'b': [2, 3]
    },
    '826161a161626163': [
      'a',
      {'b': 'c'}
    ],
  };

  test('encodes the RFC 8949 examples byte for byte', () {
    vectors.forEach((bytes, value) {
      expect(toHex(cborEncode(value)), bytes, reason: '$value');
    });
  });

  test('decodes the RFC 8949 examples', () {
    vectors.forEach((bytes, value) {
      expect(cborDecode(hex(bytes)), value, reason: bytes);
    });
  });

  test('decodes forms it never writes: small floats, tags, 64-bit ints', () {
    expect(cborDecode(hex('f93c00')), 1.0);
    expect(cborDecode(hex('f90000')), 0.0);
    expect(cborDecode(hex('f9c400')), -4.0);
    expect(cborDecode(hex('f97c00')), double.infinity);
    expect(cborDecode(hex('f90001')), 5.960464477539063e-8);
    expect(cborDecode(hex('fa47c35000')), 100000.0);
    expect(cborDecode(hex('c11a514b67b0')), 1363896240);
    expect(cborDecode(hex('1b7fffffffffffffff')), 0x7fffffffffffffff);
    expect(cborDecode(hex('3b7fffffffffffffff')), -0x8000000000000000);
  });

  test('the extremes of int round-trip', () {
    for (final n in [
      0x7fffffffffffffff,
      -0x8000000000000000,
      0xffffffff,
      0x100000000,
      -0x100000001
    ]) {
      expect(cborDecode(cborEncode(n)), n);
    }
  });

  test('random trees round-trip', () {
    final random = Random(1);
    Object? tree(int depth) => switch (random.nextInt(depth > 3 ? 6 : 8)) {
          0 => null,
          1 => random.nextBool(),
          2 => random.nextInt(1 << 32) - (1 << 31),
          3 => random.nextDouble() * 1e6,
          4 => String.fromCharCodes(List.generate(
              random.nextInt(12), (_) => 32 + random.nextInt(90))),
          5 => Uint8List.fromList(
              List.generate(random.nextInt(12), (_) => random.nextInt(256))),
          6 => List.generate(random.nextInt(5), (_) => tree(depth + 1)),
          _ => {
              for (var i = 0; i < random.nextInt(5); i++) 'k$i': tree(depth + 1)
            },
        };
    for (var i = 0; i < 500; i++) {
      final value = tree(0);
      expect(cborDecode(cborEncode(value)), value);
    }
  });

  group('hostile input', () {
    void rejects(String bytes) =>
        expect(() => cborDecode(hex(bytes)), throwsFormatException,
            reason: bytes);

    test('truncated values', () {
      rejects('');
      rejects('18');
      rejects('1903');
      rejects('6449');
      rejects('8301');
      rejects('a101');
    });

    test('lengths larger than the input do not allocate', () {
      rejects('5b7fffffffffffffff'); // bytes, length 2^63-1
      rejects('9b00000000ffffffff'); // array of four billion
      rejects('bb00000000ffffffff'); // map of four billion
      rejects('7a7fffffff'); // text of two billion
    });

    test('indefinite lengths, trailing bytes, negative lengths', () {
      rejects('9fff');
      rejects('5f41004101ff');
      rejects('0000');
      rejects('5bffffffffffffffff');
    });

    test('nesting deeper than the limit', () {
      rejects('81' * 100 + '00');
      expect(cborDecode(hex('81' * 60 + '00')), isA<List>());
    });

    test('random bytes never crash it', () {
      final random = Random(2);
      for (var i = 0; i < 5000; i++) {
        final bytes = Uint8List.fromList(
            List.generate(random.nextInt(40), (_) => random.nextInt(256)));
        try {
          cborDecode(bytes);
        } on FormatException {
          // The only acceptable failure.
        }
      }
    });
  });

  test('a value with no CBOR form is refused', () {
    expect(() => cborEncode(DateTime(2026)), throwsArgumentError);
    expect(() => cborEncode([1, Object()]), throwsArgumentError);
  });
}
