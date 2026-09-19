import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('production package stays SDK-only and Riverpod-free', () {
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in sources) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains("import 'package:")), reason: file.path);
      expect(source, isNot(contains('package:flutter')), reason: file.path);
      expect(source, isNot(contains('package:riverpod')), reason: file.path);
      expect(
        source,
        isNot(contains('package:flutter_riverpod')),
        reason: file.path,
      );
    }

    final pubspec = File('pubspec.yaml').readAsStringSync();
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
