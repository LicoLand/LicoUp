import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalized Studio source and golden SHA-256 manifest is current', () {
    expect(
      _sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    const manifestPath =
        'test/layout/profiles/studio/mobile/studio_mobile_sha256_manifest.json';
    final manifest =
        jsonDecode(File(manifestPath).readAsStringSync())
            as Map<String, dynamic>;

    final sourceFiles =
        Directory('lib/src/frontend/layout/profiles/studio/mobile')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    final goldenFiles =
        Directory('test/layout/profiles/studio/mobile/goldens')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.png'))
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));

    final sourcePaths = sourceFiles.map(_relativePath).toList();
    final goldenPaths = goldenFiles.map(_relativePath).toList();
    final sourceManifest = manifest['source'] as Map<String, dynamic>;
    final goldenManifest = manifest['goldens'] as Map<String, dynamic>;

    expect(manifest['algorithm'], 'SHA-256');
    expect(manifest['normalization'], 'sorted-relative-path+NUL+LF-bytes+NUL');
    expect(sourceManifest['files'], sourcePaths);
    expect(sourceManifest['digest'], _sourceDigest(sourceFiles));
    expect(goldenManifest['files'], goldenPaths);
    expect(goldenManifest['digest'], _binaryDigest(goldenFiles));
  });
}

String _sourceDigest(List<File> files) {
  final aggregate = <int>[];
  for (final file in files) {
    aggregate
      ..addAll(utf8.encode(_relativePath(file)))
      ..add(0)
      ..addAll(
        utf8.encode(
          file
              .readAsStringSync()
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n'),
        ),
      )
      ..add(0);
  }
  return _sha256Hex(aggregate);
}

String _binaryDigest(List<File> files) {
  final aggregate = <int>[];
  for (final file in files) {
    aggregate
      ..addAll(utf8.encode(_relativePath(file)))
      ..add(0)
      ..addAll(file.readAsBytesSync())
      ..add(0);
  }
  return _sha256Hex(aggregate);
}

String _relativePath(File file) => file.path.replaceAll('\\', '/');

const _wordMask = 0xffffffff;

const _roundConstants = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

String _sha256Hex(List<int> input) {
  final paddedLength = ((input.length + 9 + 63) ~/ 64) * 64;
  final bytes = Uint8List(paddedLength)..setRange(0, input.length, input);
  bytes[input.length] = 0x80;
  final bitLength = input.length * 8;
  for (var index = 0; index < 8; index++) {
    bytes[paddedLength - 1 - index] = (bitLength >> (index * 8)) & 0xff;
  }

  final digest = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final schedule = Uint32List(64);
  for (var chunk = 0; chunk < bytes.length; chunk += 64) {
    for (var index = 0; index < 16; index++) {
      final offset = chunk + index * 4;
      schedule[index] =
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
    }
    for (var index = 16; index < 64; index++) {
      final left = schedule[index - 15];
      final right = schedule[index - 2];
      final smallSigma0 =
          _rotateRight(left, 7) ^ _rotateRight(left, 18) ^ (left >> 3);
      final smallSigma1 =
          _rotateRight(right, 17) ^ _rotateRight(right, 19) ^ (right >> 10);
      schedule[index] =
          (schedule[index - 16] +
              smallSigma0 +
              schedule[index - 7] +
              smallSigma1) &
          _wordMask;
    }

    var a = digest[0];
    var b = digest[1];
    var c = digest[2];
    var d = digest[3];
    var e = digest[4];
    var f = digest[5];
    var g = digest[6];
    var h = digest[7];
    for (var index = 0; index < 64; index++) {
      final bigSigma1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ (((~e) & _wordMask) & g);
      final temporary1 =
          (h + bigSigma1 + choose + _roundConstants[index] + schedule[index]) &
          _wordMask;
      final bigSigma0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (bigSigma0 + majority) & _wordMask;

      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & _wordMask;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & _wordMask;
    }

    digest[0] = (digest[0] + a) & _wordMask;
    digest[1] = (digest[1] + b) & _wordMask;
    digest[2] = (digest[2] + c) & _wordMask;
    digest[3] = (digest[3] + d) & _wordMask;
    digest[4] = (digest[4] + e) & _wordMask;
    digest[5] = (digest[5] + f) & _wordMask;
    digest[6] = (digest[6] + g) & _wordMask;
    digest[7] = (digest[7] + h) & _wordMask;
  }

  return digest.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}

int _rotateRight(int value, int count) {
  return ((value >> count) | (value << (32 - count))) & _wordMask;
}
