import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production package is SDK-only and lifecycle-free', () {
    final source = File('lib/presentation_contract.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final forbidden in <String>[
      'package:',
      'Widget',
      'BuildContext',
      'ClientController',
      'dispose(',
      'close(',
      'revision',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(
      RegExp(
        r'^(?:dependencies|dependency_overrides):',
        multiLine: true,
      ).hasMatch(pubspec),
      isFalse,
      reason: 'production dependency surface',
    );
  });
}
