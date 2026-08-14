import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';

void main() {
  test('spinner arc stays circular under non-square paint constraints', () {
    final rect = licoSpinnerArcRect(const Size(12, 20), 2);

    expect(rect.width, rect.height);
    expect(rect.center, const Offset(6, 10));
  });
}
