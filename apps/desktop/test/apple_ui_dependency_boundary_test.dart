import 'dart:io';

import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Apple control foundation owns platform checks and geometry', () {
    expect(isAppleClientTargetPlatform(TargetPlatform.iOS), isTrue);
    expect(isAppleClientTargetPlatform(TargetPlatform.macOS), isTrue);
    expect(isAppleClientTargetPlatform(TargetPlatform.android), isFalse);
    expect(isAppleClientTargetPlatform(TargetPlatform.windows), isFalse);
    expect(
      AppleControlMetrics.windowCornerRadius,
      AppleControlMetrics.searchButtonRadius +
          AppleControlMetrics.searchButtonEdgeInset,
    );
    expect(
      AppleControlMetrics.topBarHeight,
      AppleControlMetrics.searchButtonSize +
          (AppleControlMetrics.searchButtonEdgeInset * 2),
    );
  });

  test('theme and Apple widgets keep an acyclic dependency direction', () {
    final theme = _source('lib/src/frontend/shared/ui/theme.dart');
    final colors = _source('lib/src/frontend/shared/ui/theme_colors.dart');
    final buttons = _source('lib/src/frontend/shared/ui/apple_buttons.dart');
    final glass = _source('lib/src/frontend/shared/ui/apple_glass.dart');
    final metrics = _source(
      'lib/src/frontend/shared/ui/apple_control_metrics.dart',
    );

    expect(theme, contains('/apple_buttons.dart'));
    expect(theme, contains('/theme_colors.dart'));
    expect(buttons, isNot(contains('/theme.dart')));
    expect(glass, isNot(contains('/theme.dart')));
    expect(colors, isNot(contains('/apple_')));
    expect(metrics, isNot(contains('/theme.dart')));
    expect(glass, isNot(contains('class AppleControlMetrics')));
  });

  test('every Apple metrics consumer imports the foundation directly', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      final fileName = file.uri.pathSegments.last;
      if (!source.contains('AppleControlMetrics') ||
          source.contains('class AppleControlMetrics') ||
          source.trimLeft().startsWith('part of ')) {
        continue;
      }
      expect(source, contains('/apple_control_metrics.dart'), reason: fileName);
    }
  });
}

String _source(String path) => File(path).readAsStringSync();
