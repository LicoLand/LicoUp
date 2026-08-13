import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const double _linuxGoldenTolerance = 0.023;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isLinux && goldenFileComparator is LocalFileComparator) {
    final localComparator = goldenFileComparator as LocalFileComparator;
    goldenFileComparator = _LinuxGoldenFileComparator(
      localComparator.basedir.resolve('flutter_test_config.dart'),
    );
  }
  await testMain();
}

final class _LinuxGoldenFileComparator extends LocalFileComparator {
  _LinuxGoldenFileComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _linuxGoldenTolerance) {
      result.dispose();
      return true;
    }

    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
